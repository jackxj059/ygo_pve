// Headless duel runner: loads ocgcore together with the real card databases and
// Lua card scripts, then drives both players from a scenario file.
// Any unexpected prompt, rejected response, script error or failed expectation
// ends the run with a non-zero exit code.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "ocgapi.h"
#include "ocgapi_constants.h"
#include "sqlite3.h"

namespace fs = std::filesystem;

namespace {

[[noreturn]] void fail(const std::string& msg) { throw std::runtime_error(msg); }

// ---------------------------------------------------------------- card data

struct CardInfo {
	OCG_CardData data{};
	std::vector<uint16_t> setcodes;
	std::string name;
	bool found = false;
};

class CardDb {
public:
	~CardDb() {
		for(auto* db : dbs_)
			sqlite3_close(db);
	}
	void open(const std::string& path) {
		sqlite3* db = nullptr;
		if(sqlite3_open_v2(path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
			std::string err = db ? sqlite3_errmsg(db) : "out of memory";
			sqlite3_close(db);
			fail("cannot open card database " + path + ": " + err);
		}
		dbs_.push_back(db);
	}
	// First database containing the code wins. Unknown codes are cached as not found.
	const CardInfo& get(uint32_t code) {
		auto it = cache_.find(code);
		if(it != cache_.end())
			return it->second;
		CardInfo& ci = cache_[code];
		ci.data.code = code;
		for(auto* db : dbs_) {
			sqlite3_stmt* st = nullptr;
			const char* sql = "SELECT d.alias,d.setcode,d.type,d.atk,d.def,d.level,d.race,d.attribute,t.name "
			                  "FROM datas d JOIN texts t ON t.id=d.id WHERE d.id=?";
			if(sqlite3_prepare_v2(db, sql, -1, &st, nullptr) != SQLITE_OK)
				fail(std::string("card database query failed: ") + sqlite3_errmsg(db));
			sqlite3_bind_int64(st, 1, code);
			if(sqlite3_step(st) == SQLITE_ROW) {
				ci.found = true;
				ci.data.alias = static_cast<uint32_t>(sqlite3_column_int64(st, 0));
				const auto setcode = static_cast<uint64_t>(sqlite3_column_int64(st, 1));
				for(int i = 0; i < 4; ++i)
					if(uint16_t sc = (setcode >> (i * 16)) & 0xffff)
						ci.setcodes.push_back(sc);
				ci.data.type = static_cast<uint32_t>(sqlite3_column_int64(st, 2));
				ci.data.attack = sqlite3_column_int(st, 3);
				ci.data.defense = sqlite3_column_int(st, 4);
				const auto level = static_cast<uint64_t>(sqlite3_column_int64(st, 5));
				ci.data.level = level & 0xff;
				ci.data.lscale = (level >> 24) & 0xff;
				ci.data.rscale = (level >> 16) & 0xff;
				ci.data.race = static_cast<uint64_t>(sqlite3_column_int64(st, 6));
				ci.data.attribute = static_cast<uint32_t>(sqlite3_column_int64(st, 7));
				if(ci.data.type & TYPE_LINK) {
					ci.data.link_marker = ci.data.defense;
					ci.data.defense = 0;
				}
				if(auto* name = sqlite3_column_text(st, 8))
					ci.name = reinterpret_cast<const char*>(name);
			}
			sqlite3_finalize(st);
			if(ci.found)
				break;
		}
		ci.setcodes.push_back(0);
		ci.data.setcodes = ci.setcodes.data();
		if(!ci.found)
			missing.insert(code);
		return ci;
	}
	std::string label(uint32_t code) {
		const auto& ci = get(code);
		return (ci.found ? ci.name : std::string("?")) + "(" + std::to_string(code) + ")";
	}
	std::set<uint32_t> missing;

private:
	std::vector<sqlite3*> dbs_;
	std::map<uint32_t, CardInfo> cache_;
};

void read_card(void* payload, uint32_t code, OCG_CardData* data) {
	*data = static_cast<CardDb*>(payload)->get(code).data;
}

// ------------------------------------------------------------------ scripts

class Scripts {
public:
	explicit Scripts(const fs::path& root) {
		// Same lookup set EDOPro ships with; the first directory listed wins on duplicates.
		for(const char* sub : {"", "official", "pre-release", "pre-errata", "unofficial", "goat", "rush", "skill"}) {
			const auto dir = root / sub;
			if(!fs::is_directory(dir))
				continue;
			for(const auto& entry : fs::directory_iterator(dir))
				if(entry.is_regular_file() && entry.path().extension() == ".lua")
					index_.emplace(entry.path().filename().string(), entry.path());
		}
		if(index_.empty())
			fail("no .lua scripts found under " + root.string());
	}
	int load(OCG_Duel duel, const char* name) {
		const auto key = fs::path(name).filename().string();
		auto it = index_.find(key);
		if(it == index_.end()) {
			missing.insert(key);
			return 0;
		}
		std::ifstream file(it->second, std::ios::binary);
		const std::string buf((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
		++loaded;
		return OCG_LoadScript(duel, buf.data(), static_cast<uint32_t>(buf.size()), name);
	}
	std::set<std::string> missing;
	int loaded = 0;

private:
	std::map<std::string, fs::path> index_;
};

int read_script(void* payload, OCG_Duel duel, const char* name) {
	return static_cast<Scripts*>(payload)->load(duel, name);
}

int g_core_errors = 0;

void on_core_log(void*, const char* text, int type) {
	static const char* const names[] = {"error", "script", "debug", "undefined"};
	std::printf("  [core %s] %s\n", names[(type >= 0 && type <= 3) ? type : 3], text);
	if(type == OCG_LOG_TYPE_ERROR)
		++g_core_errors;
}

// ----------------------------------------------------------------- scenario

struct Action {
	int line = 0;
	int player = -1; // -1 for expectations
	std::string verb;
	std::vector<std::string> args;
	std::string text;
};

struct Placement {
	uint8_t player;
	uint32_t loc;
	uint32_t code;
};

struct Scenario {
	uint64_t seed[4] = {1, 2, 3, 4};
	uint32_t lp[2] = {8000, 8000};
	uint32_t start_draw[2] = {5, 5};
	uint32_t draw_per_turn = 1;
	std::vector<Placement> cards;
	std::deque<Action> actions;
};

uint32_t parse_location(const std::string& s) {
	static const std::map<std::string, uint32_t> locs = {
		{"deck", LOCATION_DECK}, {"hand", LOCATION_HAND}, {"mzone", LOCATION_MZONE},
		{"szone", LOCATION_SZONE}, {"grave", LOCATION_GRAVE}, {"removed", LOCATION_REMOVED},
		{"extra", LOCATION_EXTRA}};
	auto it = locs.find(s);
	if(it == locs.end())
		fail("unknown location '" + s + "'");
	return it->second;
}

uint32_t to_u32(const std::string& s) { return static_cast<uint32_t>(std::stoul(s)); }

Scenario load_scenario(const fs::path& path) {
	std::ifstream in(path);
	if(!in)
		fail("cannot open scenario " + path.string());
	Scenario sc;
	std::string raw;
	for(int line_no = 1; std::getline(in, raw); ++line_no) {
		auto text = raw.substr(0, raw.find('#'));
		text.erase(text.find_last_not_of(" \t\r") + 1);
		std::istringstream ls(text);
		std::vector<std::string> tok{std::istream_iterator<std::string>(ls), {}};
		if(tok.empty())
			continue;
		try {
			const auto& kw = tok[0];
			const bool setup = sc.actions.empty();
			if(kw == "seed" && setup && tok.size() == 5) {
				for(int i = 0; i < 4; ++i)
					sc.seed[i] = std::stoull(tok[i + 1]);
			} else if(kw == "lp" && setup && tok.size() == 3) {
				sc.lp[to_u32(tok[1]) & 1] = to_u32(tok[2]);
			} else if(kw == "start_draw" && setup && tok.size() == 3) {
				sc.start_draw[to_u32(tok[1]) & 1] = to_u32(tok[2]);
			} else if(kw == "draw_per_turn" && setup && tok.size() == 2) {
				sc.draw_per_turn = to_u32(tok[1]);
			} else if(kw == "card" && setup && (tok.size() == 4 || tok.size() == 5)) {
				uint32_t copies = 1;
				if(tok.size() == 5) {
					if(tok[4].empty() || tok[4][0] != 'x')
						fail("expected copy count like x10");
					copies = to_u32(tok[4].substr(1));
				}
				for(uint32_t i = 0; i < copies; ++i)
					sc.cards.push_back({static_cast<uint8_t>(to_u32(tok[1]) & 1), parse_location(tok[2]), to_u32(tok[3])});
			} else if(kw == "expect" && tok.size() >= 2) {
				sc.actions.push_back({line_no, -1, tok[1], {tok.begin() + 2, tok.end()}, text});
			} else if((kw == "0" || kw == "1") && tok.size() >= 2) {
				sc.actions.push_back({line_no, kw[0] - '0', tok[1], {tok.begin() + 2, tok.end()}, text});
			} else {
				fail("unrecognised line (setup lines must come before actions)");
			}
		} catch(const std::exception& e) {
			fail(path.string() + ":" + std::to_string(line_no) + ": " + e.what());
		}
	}
	return sc;
}

// ------------------------------------------------------------ binary reader

class Reader {
public:
	Reader(const uint8_t* p, size_t n) : p_(p), end_(p + n) {}
	template<typename T>
	T get() {
		if(static_cast<size_t>(end_ - p_) < sizeof(T))
			fail("truncated core message");
		T v;
		std::memcpy(&v, p_, sizeof(T));
		p_ += sizeof(T);
		return v;
	}
	bool done() const { return p_ == end_; }

private:
	const uint8_t* p_;
	const uint8_t* end_;
};

struct Loc {
	uint8_t con = 0, loc = 0;
	uint32_t seq = 0, pos = 0;
};

Loc read_loc(Reader& r) {
	Loc l;
	l.con = r.get<uint8_t>();
	l.loc = r.get<uint8_t>();
	l.seq = r.get<uint32_t>();
	l.pos = r.get<uint32_t>();
	return l;
}

std::string loc_name(uint32_t loc) {
	switch(loc) {
	case LOCATION_DECK: return "deck";
	case LOCATION_HAND: return "hand";
	case LOCATION_MZONE: return "mzone";
	case LOCATION_SZONE: return "szone";
	case LOCATION_GRAVE: return "grave";
	case LOCATION_REMOVED: return "removed";
	case LOCATION_EXTRA: return "extra";
	case 0: return "-";
	default: return "loc" + std::to_string(loc);
	}
}

std::string where(const Loc& l) {
	return "p" + std::to_string(l.con) + "." + loc_name(l.loc) + "[" + std::to_string(l.seq) + "]";
}

std::string phase_name(uint16_t ph) {
	switch(ph) {
	case PHASE_DRAW: return "draw";
	case PHASE_STANDBY: return "standby";
	case PHASE_MAIN1: return "main1";
	case PHASE_BATTLE_START: return "battle-start";
	case PHASE_BATTLE_STEP: return "battle-step";
	case PHASE_DAMAGE: return "damage";
	case PHASE_DAMAGE_CAL: return "damage-calc";
	case PHASE_BATTLE: return "battle";
	case PHASE_MAIN2: return "main2";
	case PHASE_END: return "end";
	default: return "phase" + std::to_string(ph);
	}
}

struct Cand {
	uint32_t code = 0;
	Loc at;
	uint64_t desc = 0;
};

class Response {
public:
	template<typename T>
	Response& put(T v) {
		const auto n = bytes.size();
		bytes.resize(n + sizeof(T));
		std::memcpy(&bytes[n], &v, sizeof(T));
		return *this;
	}
	std::vector<uint8_t> bytes;
};

// ------------------------------------------------------------------ harness

class Harness {
public:
	Harness(Scenario sc, CardDb& db, Scripts& scripts) : sc_(std::move(sc)), db_(db), scripts_(scripts) {}
	~Harness() {
		if(duel_)
			OCG_DestroyDuel(duel_);
	}

	void run() {
		create();
		for(int iterations = 0;; ++iterations) {
			if(iterations > 20000)
				fail("duel did not finish after 20000 process calls (stuck loop?)");
			const int status = OCG_DuelProcess(duel_);
			uint32_t len = 0;
			const auto* buf = static_cast<const uint8_t*>(OCG_DuelGetMessage(duel_, &len));
			const std::vector<uint8_t> copy(buf, buf + len);
			bool answered = handle_messages(copy);
			check_core_errors();
			// The core keeps running after MSG_WIN; clients (like EDOPro's server) stop there.
			if(status == OCG_DUEL_STATUS_END || winner_seen_)
				break;
			if(status == OCG_DUEL_STATUS_AWAITING && !answered)
				fail("core is waiting for a response but sent no prompt this harness understands");
		}
		std::printf("== duel ended\n");
		run_expectations();
		if(!sc_.actions.empty())
			fail("duel ended before scenario line " + std::to_string(sc_.actions.front().line) + " was used: " + sc_.actions.front().text);
		if(!winner_seen_)
			fail("duel ended without MSG_WIN");
	}

private:
	void create() {
		OCG_DuelOptions opt{};
		std::memcpy(opt.seed, sc_.seed, sizeof(opt.seed));
		opt.flags = DUEL_MODE_MR5;
		opt.team1 = {sc_.lp[0], sc_.start_draw[0], sc_.draw_per_turn};
		opt.team2 = {sc_.lp[1], sc_.start_draw[1], sc_.draw_per_turn};
		opt.cardReader = read_card;
		opt.payload1 = &db_;
		opt.scriptReader = read_script;
		opt.payload2 = &scripts_;
		opt.logHandler = on_core_log;
		const int res = OCG_CreateDuel(&duel_, &opt);
		if(res != OCG_DUEL_CREATION_SUCCESS)
			fail("OCG_CreateDuel failed with status " + std::to_string(res));
		// The client is responsible for the two entry scripts; they pull in the rest.
		for(const char* name : {"constant.lua", "utility.lua"})
			if(!scripts_.load(duel_, name))
				fail(std::string("failed to load ") + name);
		check_core_errors();
		std::printf("== loaded %d support scripts\n", scripts_.loaded);
		for(const auto& c : sc_.cards) {
			const auto& info = db_.get(c.code);
			if(!info.found)
				fail("card " + std::to_string(c.code) + " is not in any card database");
			const uint32_t pos = (c.loc == LOCATION_GRAVE || c.loc == LOCATION_REMOVED) ? POS_FACEUP_ATTACK : POS_FACEDOWN_DEFENSE;
			OCG_NewCardInfo nc{c.player, 0, c.code, c.player, c.loc, 0, pos};
			OCG_DuelNewCard(duel_, &nc);
		}
		check_core_errors();
		// Normal monsters legitimately have no script; anything else must have one.
		for(const auto& c : sc_.cards) {
			const auto& info = db_.get(c.code);
			const bool plain_normal = (info.data.type & TYPE_NORMAL) && !(info.data.type & (TYPE_PENDULUM | TYPE_TUNER));
			if(!plain_normal && scripts_.missing.count("c" + std::to_string(c.code) + ".lua"))
				fail("script c" + std::to_string(c.code) + ".lua not found for non-normal card " + db_.label(c.code));
		}
		std::printf("== %zu cards placed, starting duel\n", sc_.cards.size());
		OCG_StartDuel(duel_);
	}

	void check_core_errors() {
		if(g_core_errors)
			fail(std::to_string(g_core_errors) + " core/script error(s) reported (see [core error] lines)");
		if(!db_.missing.empty())
			fail("core requested unknown card code " + std::to_string(*db_.missing.begin()));
	}

	// Returns true if a prompt was answered.
	bool handle_messages(const std::vector<uint8_t>& buf) {
		Reader outer(buf.data(), buf.size());
		bool answered = false;
		while(!outer.done() && !winner_seen_) {
			const auto size = outer.get<uint32_t>();
			std::vector<uint8_t> body(size);
			for(auto& b : body)
				b = outer.get<uint8_t>();
			if(body.empty())
				fail("empty core message");
			Reader r(body.data() + 1, body.size() - 1);
			if(on_message(body[0], r))
				answered = true;
		}
		return answered;
	}

	bool on_message(uint8_t type, Reader& r) {
		switch(type) {
		case MSG_RETRY:
			fail("core rejected the last response (MSG_RETRY)");
		case MSG_WIN: {
			const auto p = r.get<uint8_t>();
			const auto reason = r.get<uint8_t>();
			winner_ = p;
			win_reason_ = reason;
			winner_seen_ = true;
			std::printf("WIN player=%u reason=%u (%s)\n", p, reason, reason == 1 ? "LP" : reason == 2 ? "deck-out" : "card effect/other");
			return false;
		}
		case MSG_NEW_TURN:
			++turn_;
			std::printf("\n--- turn %d (player %u)\n", turn_, r.get<uint8_t>());
			return false;
		case MSG_NEW_PHASE:
			std::printf("  phase %s\n", phase_name(r.get<uint16_t>()).c_str());
			return false;
		case MSG_DRAW: {
			const auto p = r.get<uint8_t>();
			const auto n = r.get<uint32_t>();
			std::string s;
			for(uint32_t i = 0; i < n; ++i) {
				s += " " + db_.label(r.get<uint32_t>() & 0x7fffffff);
				r.get<uint32_t>();
			}
			std::printf("  p%u draws%s\n", p, s.c_str());
			return false;
		}
		case MSG_MOVE: {
			const auto code = r.get<uint32_t>();
			const auto from = read_loc(r);
			const auto to = read_loc(r);
			const auto reason = r.get<uint32_t>();
			std::printf("  move %s %s -> %s reason=0x%x\n", db_.label(code).c_str(), where(from).c_str(), where(to).c_str(), reason);
			return false;
		}
		case MSG_SUMMONING:
		case MSG_SPSUMMONING:
		case MSG_FLIPSUMMONING: {
			const auto code = r.get<uint32_t>();
			const auto at = read_loc(r);
			const char* kind = type == MSG_SUMMONING ? "normal summon" : type == MSG_SPSUMMONING ? "special summon" : "flip summon";
			std::printf("  %s %s at %s pos=0x%x\n", kind, db_.label(code).c_str(), where(at).c_str(), at.pos);
			return false;
		}
		case MSG_SET: {
			const auto code = r.get<uint32_t>();
			std::printf("  set %s at %s\n", db_.label(code).c_str(), where(read_loc(r)).c_str());
			return false;
		}
		case MSG_CHAINING: {
			const auto code = r.get<uint32_t>();
			const auto at = read_loc(r);
			r.get<uint8_t>();
			r.get<uint8_t>();
			r.get<uint32_t>();
			r.get<uint64_t>();
			const auto link = r.get<uint32_t>();
			chain_.push_back(code);
			const bool prompted = last_prompt_code_ == code;
			std::printf("  CHAIN LINK %u: %s from %s (%s)\n", link, db_.label(code).c_str(), where(at).c_str(),
			            prompted ? "chosen by player" : "activated without a player prompt");
			last_prompt_code_ = 0;
			return false;
		}
		case MSG_CHAIN_SOLVING: {
			const auto link = r.get<uint8_t>();
			if(link == 0 || link > chain_.size())
				fail("CHAIN_SOLVING for unknown link " + std::to_string(link));
			resolved_.push_back(chain_[link - 1]);
			std::printf("  resolve link %u: %s\n", link, db_.label(chain_[link - 1]).c_str());
			return false;
		}
		case MSG_CHAIN_NEGATED:
		case MSG_CHAIN_DISABLED:
			std::printf("  link %u %s\n", r.get<uint8_t>(), type == MSG_CHAIN_NEGATED ? "activation negated" : "effect negated");
			return false;
		case MSG_CHAIN_END:
			std::printf("  chain end\n");
			last_chain_ = resolved_;
			chain_.clear();
			resolved_.clear();
			return false;
		case MSG_DAMAGE:
		case MSG_RECOVER:
		case MSG_PAY_LPCOST: {
			const auto p = r.get<uint8_t>();
			const auto amount = r.get<uint32_t>();
			const char* kind = type == MSG_DAMAGE ? "takes damage" : type == MSG_RECOVER ? "recovers" : "pays LP";
			std::printf("  p%u %s %u\n", p, kind, amount);
			return false;
		}
		case MSG_ATTACK: {
			const auto a = read_loc(r);
			const auto d = read_loc(r);
			std::printf("  attack %s -> %s\n", where(a).c_str(), d.loc ? where(d).c_str() : "direct");
			return false;
		}
		case MSG_SELECT_IDLECMD: return on_idle(r);
		case MSG_SELECT_BATTLECMD: return on_battle(r);
		case MSG_SELECT_EFFECTYN: {
			const auto p = r.get<uint8_t>();
			const auto code = r.get<uint32_t>();
			const auto at = read_loc(r);
			std::printf("? p%u optional effect of %s at %s: activate?\n", p, db_.label(code).c_str(), where(at).c_str());
			const auto act = take(p, "yesno", "SELECT_EFFECTYN");
			const bool yes = arg(act, 0) == "yes";
			if(yes)
				last_prompt_code_ = code;
			return respond(Response().put<int32_t>(yes ? 1 : 0), act.text);
		}
		case MSG_SELECT_YESNO: {
			const auto p = r.get<uint8_t>();
			std::printf("? p%u yes/no (desc %llu)\n", p, static_cast<unsigned long long>(r.get<uint64_t>()));
			const auto act = take(p, "yesno", "SELECT_YESNO");
			return respond(Response().put<int32_t>(arg(act, 0) == "yes" ? 1 : 0), act.text);
		}
		case MSG_SELECT_OPTION: {
			const auto p = r.get<uint8_t>();
			const auto n = r.get<uint8_t>();
			std::printf("? p%u choose option (0..%u)\n", p, n - 1u);
			const auto act = take(p, "option", "SELECT_OPTION");
			const auto idx = std::stoi(arg(act, 0));
			if(idx < 0 || idx >= n)
				fail("option index out of range at line " + std::to_string(act.line));
			return respond(Response().put<int32_t>(idx), act.text);
		}
		case MSG_SELECT_CARD:
		case MSG_SELECT_TRIBUTE: {
			const auto p = r.get<uint8_t>();
			r.get<uint8_t>(); // cancelable
			const auto min = r.get<uint32_t>();
			const auto max = r.get<uint32_t>();
			const auto n = r.get<uint32_t>();
			std::vector<Cand> cands(n);
			for(auto& c : cands) {
				c.code = r.get<uint32_t>();
				if(type == MSG_SELECT_CARD) {
					c.at = read_loc(r);
				} else {
					c.at.con = r.get<uint8_t>();
					c.at.loc = r.get<uint8_t>();
					c.at.seq = r.get<uint32_t>();
					r.get<uint8_t>(); // release param
				}
			}
			std::printf("? p%u select %u-%u of:%s\n", p, min, max, list(cands).c_str());
			const auto act = take(p, "select", type == MSG_SELECT_CARD ? "SELECT_CARD" : "SELECT_TRIBUTE");
			Response resp;
			resp.put<int32_t>(0).put<uint32_t>(static_cast<uint32_t>(act.args.size()));
			std::set<uint32_t> used;
			for(const auto& code : act.args)
				resp.put<uint32_t>(pick(cands, to_u32(code), used, act));
			return respond(resp, act.text);
		}
		case MSG_SELECT_UNSELECT_CARD: {
			const auto p = r.get<uint8_t>();
			r.get<uint8_t>(); // finishable
			r.get<uint8_t>(); // cancelable
			r.get<uint32_t>();
			r.get<uint32_t>();
			std::vector<Cand> cands(r.get<uint32_t>());
			for(auto& c : cands) {
				c.code = r.get<uint32_t>();
				c.at = read_loc(r);
			}
			const auto selected = r.get<uint32_t>();
			for(uint32_t i = 0; i < selected; ++i) {
				Cand c;
				c.code = r.get<uint32_t>();
				c.at = read_loc(r);
				cands.push_back(c);
			}
			std::printf("? p%u select/unselect one of:%s\n", p, list(cands).c_str());
			const auto act = take(p, "select", "SELECT_UNSELECT_CARD");
			if(arg(act, 0) == "finish")
				return respond(Response().put<int32_t>(-1), act.text);
			std::set<uint32_t> used;
			return respond(Response().put<int32_t>(1).put<int32_t>(static_cast<int32_t>(pick(cands, to_u32(arg(act, 0)), used, act))), act.text);
		}
		case MSG_SELECT_CHAIN: return on_chain(r);
		case MSG_SELECT_PLACE:
		case MSG_SELECT_DISFIELD: {
			const auto p = r.get<uint8_t>();
			const auto count = r.get<uint8_t>();
			auto flag = r.get<uint32_t>();
			Response resp;
			std::string chosen;
			for(int i = 0; i < count; ++i) {
				// Bits set in flag are unavailable. Prefer own zones, monster zones first.
				// Bit 7 of each half has no monster zone behind it.
				int bit = 0;
				while(bit < 32 && ((flag & (1u << bit)) || bit % 16 == 7))
					++bit;
				if(bit == 32)
					fail("SELECT_PLACE with no free zone");
				flag |= 1u << bit;
				const uint8_t owner = bit < 16 ? p : 1 - p;
				const uint8_t loc = (bit % 16) < 8 ? LOCATION_MZONE : LOCATION_SZONE;
				const uint8_t seq = bit % 8;
				resp.put<uint8_t>(owner).put<uint8_t>(loc).put<uint8_t>(seq);
				chosen += " p" + std::to_string(owner) + "." + loc_name(loc) + "[" + std::to_string(seq) + "]";
			}
			std::printf("? p%u place -> default%s\n", p, chosen.c_str());
			return respond(resp, "");
		}
		case MSG_SELECT_POSITION: {
			const auto p = r.get<uint8_t>();
			const auto code = r.get<uint32_t>();
			const auto allowed = r.get<uint8_t>();
			static const std::map<std::string, uint8_t> names = {
				{"fu_atk", POS_FACEUP_ATTACK}, {"fd_atk", POS_FACEDOWN_ATTACK},
				{"fu_def", POS_FACEUP_DEFENSE}, {"fd_def", POS_FACEDOWN_DEFENSE}};
			uint8_t pos = 0;
			std::string text = "default";
			if(next_is(p, "position")) {
				const auto act = take(p, "position", "SELECT_POSITION");
				auto it = names.find(arg(act, 0));
				if(it == names.end())
					fail("unknown position at line " + std::to_string(act.line));
				pos = it->second;
				text = act.text;
			} else {
				for(uint8_t c : {POS_FACEUP_ATTACK, POS_FACEUP_DEFENSE, POS_FACEDOWN_DEFENSE, POS_FACEDOWN_ATTACK})
					if(allowed & c) {
						pos = c;
						break;
					}
			}
			std::printf("? p%u position for %s (allowed 0x%x) -> 0x%x [%s]\n", p, db_.label(code).c_str(), allowed, pos, text.c_str());
			return respond(Response().put<int32_t>(pos), "");
		}
		case MSG_SORT_CHAIN:
		case MSG_SORT_CARD:
			std::printf("? p%u sort -> default order\n", r.get<uint8_t>());
			return respond(Response().put<int8_t>(-1), "");
		case MSG_SELECT_COUNTER:
		case MSG_SELECT_SUM:
		case MSG_ANNOUNCE_RACE:
		case MSG_ANNOUNCE_ATTRIB:
		case MSG_ANNOUNCE_CARD:
		case MSG_ANNOUNCE_NUMBER:
		case MSG_ROCK_PAPER_SCISSORS:
			fail("prompt type " + std::to_string(type) + " is not supported by this harness yet");
		default:
			return false; // informational message the harness does not need
		}
	}

	bool on_idle(Reader& r) {
		const auto p = r.get<uint8_t>();
		static const char* const verbs[] = {"summon", "spsummon", "repos", "mset", "sset", "activate"};
		std::vector<Cand> lists[6];
		for(int t = 0; t < 6; ++t) {
			lists[t].resize(r.get<uint32_t>());
			for(auto& c : lists[t]) {
				c.code = r.get<uint32_t>();
				c.at.con = r.get<uint8_t>();
				c.at.loc = r.get<uint8_t>();
				c.at.seq = t == 2 ? r.get<uint8_t>() : r.get<uint32_t>();
				if(t == 5) {
					c.desc = r.get<uint64_t>();
					r.get<uint8_t>();
				}
			}
		}
		const bool to_bp = r.get<uint8_t>();
		const bool to_ep = r.get<uint8_t>();
		std::printf("? p%u idle:", p);
		for(int t = 0; t < 6; ++t)
			if(!lists[t].empty())
				std::printf(" %s[%s]", verbs[t], list(lists[t]).c_str() + 1);
		std::printf("%s%s\n", to_bp ? " battle" : "", to_ep ? " end" : "");
		const auto act = take(p, "idle", "SELECT_IDLECMD");
		const auto what = arg(act, 0);
		int32_t resp = -1;
		if(what == "battle" && to_bp)
			resp = 6;
		else if(what == "end" && to_ep)
			resp = 7;
		for(int t = 0; t < 6 && resp < 0; ++t) {
			if(what != verbs[t])
				continue;
			std::set<uint32_t> used;
			const auto idx = pick(lists[t], to_u32(arg(act, 1)), used, act);
			if(t == 5)
				last_prompt_code_ = lists[t][idx].code;
			resp = static_cast<int32_t>(idx << 16) | t;
		}
		if(resp < 0)
			fail("line " + std::to_string(act.line) + ": '" + what + "' is not available right now");
		return respond(Response().put<int32_t>(resp), act.text);
	}

	bool on_battle(Reader& r) {
		const auto p = r.get<uint8_t>();
		std::vector<Cand> acts(r.get<uint32_t>());
		for(auto& c : acts) {
			c.code = r.get<uint32_t>();
			c.at.con = r.get<uint8_t>();
			c.at.loc = r.get<uint8_t>();
			c.at.seq = r.get<uint32_t>();
			c.desc = r.get<uint64_t>();
			r.get<uint8_t>();
		}
		std::vector<Cand> attackers(r.get<uint32_t>());
		for(auto& c : attackers) {
			c.code = r.get<uint32_t>();
			c.at.con = r.get<uint8_t>();
			c.at.loc = r.get<uint8_t>();
			c.at.seq = r.get<uint8_t>();
			r.get<uint8_t>(); // can attack directly
		}
		const bool to_m2 = r.get<uint8_t>();
		const bool to_ep = r.get<uint8_t>();
		std::printf("? p%u battle:%s%s%s%s%s\n", p, acts.empty() ? "" : (" activate[" + list(acts).substr(1) + "]").c_str(),
		            attackers.empty() ? "" : (" attack[" + list(attackers).substr(1) + "]").c_str(), "", to_m2 ? " main2" : "", to_ep ? " end" : "");
		const auto act = take(p, "battle", "SELECT_BATTLECMD");
		const auto what = arg(act, 0);
		std::set<uint32_t> used;
		int32_t resp = -1;
		if(what == "activate") {
			const auto idx = pick(acts, to_u32(arg(act, 1)), used, act);
			last_prompt_code_ = acts[idx].code;
			resp = static_cast<int32_t>(idx << 16) | 0;
		} else if(what == "attack") {
			resp = static_cast<int32_t>(pick(attackers, to_u32(arg(act, 1)), used, act) << 16) | 1;
		} else if(what == "main2" && to_m2) {
			resp = 2;
		} else if(what == "end" && to_ep) {
			resp = 3;
		} else {
			fail("line " + std::to_string(act.line) + ": '" + what + "' is not available right now");
		}
		return respond(Response().put<int32_t>(resp), act.text);
	}

	bool on_chain(Reader& r) {
		const auto p = r.get<uint8_t>();
		r.get<uint8_t>(); // spe_count
		const bool forced = r.get<uint8_t>();
		r.get<uint32_t>();
		r.get<uint32_t>();
		std::vector<Cand> cands(r.get<uint32_t>());
		for(auto& c : cands) {
			c.code = r.get<uint32_t>();
			c.at = read_loc(r);
			c.desc = r.get<uint64_t>();
			r.get<uint8_t>();
		}
		if(cands.empty() && !forced) {
			return respond(Response().put<int32_t>(-1), "");
		}
		// A chain action is only consumed when it is the next scripted step, so
		// earlier windows where the same card could be activated are passed.
		if(next_is(p, "chain")) {
			const auto act = take(p, "chain", "SELECT_CHAIN");
			std::printf("? p%u chain window%s:%s\n", p, forced ? " (forced)" : "", list(cands).c_str());
			if(arg(act, 0) == "pass") {
				if(forced)
					fail("line " + std::to_string(act.line) + ": cannot pass a forced chain");
				return respond(Response().put<int32_t>(-1), act.text);
			}
			std::set<uint32_t> used;
			const auto idx = pick(cands, to_u32(arg(act, 0)), used, act);
			last_prompt_code_ = cands[idx].code;
			return respond(Response().put<int32_t>(static_cast<int32_t>(idx)), act.text);
		}
		if(forced) {
			if(cands.size() != 1)
				fail("forced chain with " + std::to_string(cands.size()) + " options needs a scripted 'chain' for p" + std::to_string(p));
			std::printf("? p%u forced chain:%s -> only option\n", p, list(cands).c_str());
			return respond(Response().put<int32_t>(0), "");
		}
		std::printf("? p%u chain window:%s -> pass (not scripted)\n", p, list(cands).c_str());
		return respond(Response().put<int32_t>(-1), "");
	}

	// ---- scenario helpers

	// Peeks past pending expectations: those only run when a scripted action is
	// consumed, never at prompts the harness answers by default.
	bool next_is(uint8_t player, const char* verb) {
		for(const auto& act : sc_.actions)
			if(act.player != -1)
				return act.player == player && act.verb == verb;
		return false;
	}

	Action take(uint8_t player, const char* verb, const char* prompt) {
		run_expectations();
		if(sc_.actions.empty())
			fail(std::string("unscripted ") + prompt + " for p" + std::to_string(player) + ": scenario has no actions left");
		auto act = sc_.actions.front();
		if(act.player != player || act.verb != verb)
			fail(std::string("got ") + prompt + " for p" + std::to_string(player) + " but scenario line " + std::to_string(act.line) + " expects: " + act.text);
		sc_.actions.pop_front();
		return act;
	}

	static std::string arg(const Action& act, size_t i) {
		if(i >= act.args.size())
			fail("line " + std::to_string(act.line) + ": missing argument");
		return act.args[i];
	}

	uint32_t pick(const std::vector<Cand>& cands, uint32_t code, std::set<uint32_t>& used, const Action& act) {
		for(uint32_t i = 0; i < cands.size(); ++i)
			if(cands[i].code == code && !used.count(i)) {
				used.insert(i);
				return i;
			}
		fail("line " + std::to_string(act.line) + ": " + db_.label(code) + " is not among the offered choices");
	}

	std::string list(const std::vector<Cand>& cands) {
		std::string s;
		for(const auto& c : cands)
			s += " " + db_.label(c.code) + "@" + where(c.at);
		return s;
	}

	bool respond(const Response& resp, const std::string& text) {
		if(!text.empty())
			std::printf("  > %s\n", text.c_str());
		OCG_DuelSetResponse(duel_, resp.bytes.data(), static_cast<uint32_t>(resp.bytes.size()));
		return true;
	}

	uint32_t query_lp(uint8_t player) {
		uint32_t len = 0;
		const auto* buf = static_cast<const uint8_t*>(OCG_DuelQueryField(duel_, &len));
		Reader r(buf, len);
		r.get<uint32_t>(); // duel options
		for(uint8_t p = 0;; ++p) {
			const auto lp = r.get<uint32_t>();
			if(p == player)
				return lp;
			for(int zone = 0; zone < 7 + 8; ++zone)
				if(r.get<uint8_t>()) {
					r.get<uint8_t>();
					r.get<uint32_t>();
				}
			for(int i = 0; i < 6; ++i)
				r.get<uint32_t>();
		}
	}

	void run_expectations() {
		while(!sc_.actions.empty() && sc_.actions.front().player == -1) {
			const auto act = sc_.actions.front();
			sc_.actions.pop_front();
			std::string got, want;
			if(act.verb == "lp") {
				got = std::to_string(query_lp(to_u32(arg(act, 0)) & 1));
				want = arg(act, 1);
			} else if(act.verb == "count") {
				got = std::to_string(OCG_DuelQueryCount(duel_, to_u32(arg(act, 0)) & 1, parse_location(arg(act, 1))));
				want = arg(act, 2);
			} else if(act.verb == "chain") {
				for(auto code : last_chain_)
					got += (got.empty() ? "" : " ") + std::to_string(code);
				for(const auto& a : act.args)
					want += (want.empty() ? "" : " ") + a;
			} else if(act.verb == "win") {
				got = winner_seen_ ? std::to_string(winner_) + (act.args.size() > 1 ? " " + std::to_string(win_reason_) : "") : "none";
				for(const auto& a : act.args)
					want += (want.empty() ? "" : " ") + a;
			} else {
				fail("line " + std::to_string(act.line) + ": unknown expectation '" + act.verb + "'");
			}
			if(got != want)
				fail("expectation failed at line " + std::to_string(act.line) + " (" + act.text + "): got " + got);
			std::printf("  ok: expect %s\n", act.text.substr(act.text.find(act.verb)).c_str());
		}
	}

	Scenario sc_;
	CardDb& db_;
	Scripts& scripts_;
	OCG_Duel duel_ = nullptr;
	int turn_ = 0;
	std::vector<uint32_t> chain_, resolved_, last_chain_;
	uint32_t last_prompt_code_ = 0;
	bool winner_seen_ = false;
	uint8_t winner_ = 0, win_reason_ = 0;
};

} // namespace

int main(int argc, char** argv) {
	std::setvbuf(stdout, nullptr, _IONBF, 0);
	std::string scripts_dir, scenario;
	std::vector<std::string> dbs;
	for(int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		if(a == "--scripts" && i + 1 < argc)
			scripts_dir = argv[++i];
		else if(a == "--db" && i + 1 < argc)
			dbs.push_back(argv[++i]);
		else
			scenario = a;
	}
	if(scripts_dir.empty() || dbs.empty() || scenario.empty()) {
		std::fprintf(stderr, "usage: duel_harness --scripts DIR --db FILE [--db FILE...] SCENARIO\n");
		return 2;
	}
	try {
		int major = 0, minor = 0;
		OCG_GetVersion(&major, &minor);
		std::printf("== ocgcore API %d.%d (harness built against %d.%d)\n", major, minor, OCG_VERSION_MAJOR, OCG_VERSION_MINOR);
		if(major != OCG_VERSION_MAJOR)
			fail("ocgcore API major version mismatch");
		CardDb db;
		for(const auto& path : dbs)
			db.open(path);
		Scripts scripts(scripts_dir);
		std::printf("== scenario %s\n", scenario.c_str());
		Harness(load_scenario(scenario), db, scripts).run();
	} catch(const std::exception& e) {
		std::printf("FAIL: %s\n", e.what());
		return 1;
	}
	std::printf("PASS\n");
	return 0;
}
