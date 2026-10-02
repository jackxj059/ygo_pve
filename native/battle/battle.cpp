#include "battle.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include "ocgapi.h"
#include "ocgapi_constants.h"
#include "sqlite3.h"

namespace fs = std::filesystem;

namespace battle {
namespace {

[[noreturn]] void fail(const std::string& msg) { throw std::runtime_error(msg); }

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
	void skip(size_t n) {
		if(static_cast<size_t>(end_ - p_) < n)
			fail("truncated core message");
		p_ += n;
	}
	bool done() const { return p_ == end_; }

private:
	const uint8_t* p_;
	const uint8_t* end_;
};

CardRef read_loc(Reader& r, uint32_t code = 0) {
	CardRef c;
	c.code = code;
	c.controller = r.get<uint8_t>();
	c.location = r.get<uint8_t>();
	c.sequence = r.get<uint32_t>();
	c.position = r.get<uint32_t>();
	return c;
}

// code, controller u8, location u8, sequence (u8 or u32) -- the short form used in command lists
CardRef read_short(Reader& r, bool seq32) {
	CardRef c;
	c.code = r.get<uint32_t>();
	c.controller = r.get<uint8_t>();
	c.location = r.get<uint8_t>();
	c.sequence = seq32 ? r.get<uint32_t>() : r.get<uint8_t>();
	return c;
}

template<typename T>
std::vector<uint8_t> bytes(T v) {
	std::vector<uint8_t> b(sizeof(T));
	std::memcpy(b.data(), &v, sizeof(T));
	return b;
}

template<typename T>
void append(std::vector<uint8_t>& b, T v) {
	const auto n = b.size();
	b.resize(n + sizeof(T));
	std::memcpy(&b[n], &v, sizeof(T));
}

// Fixed algorithm (splitmix64 + Fisher-Yates) so the deck order depends only on the
// seed, not on which standard library the module is compiled with.
void shuffle(std::vector<uint32_t>& cards, const uint64_t seed[4], uint8_t player) {
	uint64_t s = seed[0] ^ (seed[1] << 16 | seed[1] >> 48) ^ (seed[2] << 32 | seed[2] >> 32) ^
	             (seed[3] << 48 | seed[3] >> 16) ^ (0x5851f42d4c957f2dULL * (player + 1u));
	auto next = [&s] {
		uint64_t z = (s += 0x9e3779b97f4a7c15ULL);
		z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
		z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
		return z ^ (z >> 31);
	};
	for(size_t i = cards.size(); i > 1; --i)
		std::swap(cards[i - 1], cards[next() % i]); // ponytail: modulo bias is negligible for deck sizes
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

std::string phase_name(uint32_t ph) {
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

} // namespace

// ------------------------------------------------------------------ Content

Content::Content(const std::string& scripts_dir, const std::vector<std::string>& db_paths) {
	for(const auto& path : db_paths) {
		sqlite3* db = nullptr;
		if(sqlite3_open_v2(path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
			std::string err = db ? sqlite3_errmsg(db) : "out of memory";
			sqlite3_close(db);
			for(auto* d : dbs_)
				sqlite3_close(d);
			fail("cannot open card database " + path + ": " + err);
		}
		dbs_.push_back(db);
	}
	// Same lookup set EDOPro ships with; the first directory listed wins on duplicates.
	const fs::path root(scripts_dir);
	for(const char* sub : {"", "official", "pre-release", "pre-errata", "unofficial", "goat", "rush", "skill"}) {
		const auto dir = root / sub;
		if(!fs::is_directory(dir))
			continue;
		for(const auto& entry : fs::directory_iterator(dir))
			if(entry.is_regular_file() && entry.path().extension() == ".lua")
				scripts_.emplace(entry.path().filename().string(), entry.path().string());
	}
	if(scripts_.empty()) {
		for(auto* d : dbs_)
			sqlite3_close(d);
		fail("no .lua scripts found under " + scripts_dir);
	}
}

Content::~Content() {
	for(auto* db : dbs_)
		sqlite3_close(db);
}

const CardData& Content::card(uint32_t code) {
	auto it = cache_.find(code);
	if(it != cache_.end())
		return it->second;
	CardData& cd = cache_[code];
	cd.code = code;
	for(auto* db : dbs_) {
		sqlite3_stmt* st = nullptr;
		const char* sql = "SELECT d.alias,d.setcode,d.type,d.atk,d.def,d.level,d.race,d.attribute,t.name "
		                  "FROM datas d JOIN texts t ON t.id=d.id WHERE d.id=?";
		if(sqlite3_prepare_v2(db, sql, -1, &st, nullptr) != SQLITE_OK)
			fail(std::string("card database query failed: ") + sqlite3_errmsg(db));
		sqlite3_bind_int64(st, 1, code);
		if(sqlite3_step(st) == SQLITE_ROW) {
			cd.found = true;
			cd.alias = static_cast<uint32_t>(sqlite3_column_int64(st, 0));
			const auto setcode = static_cast<uint64_t>(sqlite3_column_int64(st, 1));
			for(int i = 0; i < 4; ++i)
				if(uint16_t sc = (setcode >> (i * 16)) & 0xffff)
					cd.setcodes.push_back(sc);
			cd.type = static_cast<uint32_t>(sqlite3_column_int64(st, 2));
			cd.attack = sqlite3_column_int(st, 3);
			cd.defense = sqlite3_column_int(st, 4);
			const auto level = static_cast<uint64_t>(sqlite3_column_int64(st, 5));
			cd.level = level & 0xff;
			cd.lscale = (level >> 24) & 0xff;
			cd.rscale = (level >> 16) & 0xff;
			cd.race = static_cast<uint64_t>(sqlite3_column_int64(st, 6));
			cd.attribute = static_cast<uint32_t>(sqlite3_column_int64(st, 7));
			if(cd.type & TYPE_LINK) {
				cd.link_marker = cd.defense;
				cd.defense = 0;
			}
			if(auto* name = sqlite3_column_text(st, 8))
				cd.name = reinterpret_cast<const char*>(name);
		}
		sqlite3_finalize(st);
		if(cd.found)
			break;
	}
	cd.setcodes.push_back(0);
	return cd;
}

std::string Content::label(uint32_t code) {
	const auto& cd = card(code);
	return (cd.found ? cd.name : std::string("?")) + "(" + std::to_string(code) + ")";
}

const std::string* Content::script_path(const std::string& name) const {
	auto it = scripts_.find(fs::path(name).filename().string());
	return it == scripts_.end() ? nullptr : &it->second;
}

// --------------------------------------------------------------------- Duel

Duel::Duel(Content& content, const DuelConfig& config) : content_(content) {
	OCG_DuelOptions opt{};
	std::memcpy(opt.seed, config.seed, sizeof(opt.seed));
	opt.flags = config.flags ? config.flags : DUEL_MODE_MR5;
	const auto& p0 = config.players[0];
	const auto& p1 = config.players[1];
	opt.team1 = {p0.lp, p0.start_draw, p0.draw_per_turn};
	opt.team2 = {p1.lp, p1.start_draw, p1.draw_per_turn};
	opt.cardReader = [](void* self, uint32_t code, OCG_CardData* out) { static_cast<Duel*>(self)->on_card_request(code, out); };
	opt.payload1 = this;
	opt.scriptReader = [](void* self, OCG_Duel, const char* name) { return static_cast<Duel*>(self)->on_script_request(name); };
	opt.payload2 = this;
	opt.logHandler = [](void* self, const char* text, int type) { static_cast<Duel*>(self)->on_log(text, type); };
	opt.payload3 = this;
	const int res = OCG_CreateDuel(&duel_, &opt);
	if(res != OCG_DUEL_CREATION_SUCCESS)
		fail("OCG_CreateDuel failed with status " + std::to_string(res));
	try {
		// The host is responsible for the two entry scripts; they pull in the rest.
		for(const char* name : {"constant.lua", "utility.lua"})
			if(!on_script_request(name))
				fail(std::string("failed to load ") + name);
		std::vector<std::pair<uint32_t, CardOrigin>> added; // creation order
		auto add = [&](uint8_t player, uint32_t loc, uint32_t code, const std::string& what, CardOrigin origin) {
			if(!content_.card(code).found)
				fail(what + ": unknown card code " + std::to_string(code));
			const uint32_t pos = (loc == LOCATION_GRAVE || loc == LOCATION_REMOVED) ? POS_FACEUP_ATTACK : POS_FACEDOWN_DEFENSE;
			OCG_NewCardInfo nc{player, 0, code, player, loc, 0, pos};
			OCG_DuelNewCard(duel_, &nc);
			added.push_back({code, origin});
		};
		using Source = CardOrigin::Source;
		for(uint8_t p = 0; p < 2; ++p) {
			const auto& main = config.players[p].main;
			std::vector<uint32_t> order(main.size());
			for(uint32_t i = 0; i < order.size(); ++i)
				order[i] = i;
			shuffle(order, config.seed, p);
			for(auto i : order)
				add(p, LOCATION_DECK, main[i], "p" + std::to_string(p) + " main deck", {p, Source::Main, i});
			const auto& extra = config.players[p].extra;
			for(uint32_t i = 0; i < extra.size(); ++i)
				add(p, LOCATION_EXTRA, extra[i], "p" + std::to_string(p) + " extra deck", {p, Source::Extra, i});
		}
		for(uint32_t i = 0; i < config.placements.size(); ++i) {
			const auto& pl = config.placements[i];
			add(pl.player & 1, pl.location, pl.code, "p" + std::to_string(pl.player) + " " + loc_name(pl.location) + " placement",
			    {static_cast<uint8_t>(pl.player & 1), Source::Placement, i});
		}
		// Normal monsters legitimately have no script; anything else must have one.
		for(const auto& [code, origin] : added) {
			const auto& cd = content_.card(code);
			const bool plain_normal = (cd.type & TYPE_NORMAL) && !(cd.type & (TYPE_PENDULUM | TYPE_TUNER));
			if(!plain_normal && missing_scripts_.count("c" + std::to_string(code) + ".lua"))
				fail("script c" + std::to_string(code) + ".lua not found for non-normal card " + content_.label(code));
		}
		// The core numbers cards in creation order, so sorting the ids recovers which
		// config entry became which instance.
		std::vector<CardRef> present;
		for(uint8_t p = 0; p < 2; ++p)
			for(uint32_t loc : {LOCATION_DECK, LOCATION_HAND, LOCATION_MZONE, LOCATION_SZONE, LOCATION_GRAVE, LOCATION_REMOVED, LOCATION_EXTRA})
				for(const auto& c : cards(p, loc))
					if(c.code)
						present.push_back(c);
		if(present.size() != added.size())
			fail("core accepted " + std::to_string(present.size()) + " of " + std::to_string(added.size()) + " cards (a placement may target a full or invalid zone)");
		std::sort(present.begin(), present.end(), [](const CardRef& a, const CardRef& b) { return a.instance < b.instance; });
		for(size_t i = 0; i < present.size(); ++i) {
			if(present[i].code != added[i].first)
				fail("card instance ids do not follow creation order; cannot map instances to the deck config");
			origins_[present[i].instance] = added[i].second;
		}
		if(status_ == Status::Error)
			fail(error_);
		OCG_StartDuel(duel_);
	} catch(...) {
		OCG_DestroyDuel(duel_);
		throw;
	}
}

Duel::~Duel() {
	OCG_DestroyDuel(duel_);
}

void Duel::on_card_request(uint32_t code, void* out) {
	const auto& cd = content_.card(code);
	if(!cd.found)
		set_error("core requested unknown card code " + std::to_string(code));
	auto& data = *static_cast<OCG_CardData*>(out);
	data = OCG_CardData{};
	data.code = cd.code;
	data.alias = cd.alias;
	data.setcodes = const_cast<uint16_t*>(cd.setcodes.data()); // cached, outlives the call
	data.type = cd.type;
	data.level = cd.level;
	data.attribute = cd.attribute;
	data.race = cd.race;
	data.attack = cd.attack;
	data.defense = cd.defense;
	data.lscale = cd.lscale;
	data.rscale = cd.rscale;
	data.link_marker = cd.link_marker;
}

int Duel::on_script_request(const char* name) {
	const auto* path = content_.script_path(name);
	if(!path) {
		missing_scripts_.insert(fs::path(name).filename().string());
		return 0;
	}
	std::ifstream file(*path, std::ios::binary);
	const std::string buf((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
	return OCG_LoadScript(duel_, buf.data(), static_cast<uint32_t>(buf.size()), name);
}

void Duel::on_log(const char* text, int type) {
	if(type == OCG_LOG_TYPE_ERROR)
		set_error(std::string("core/script error: ") + text);
}

void Duel::set_error(const std::string& msg) {
	if(status_ == Status::Error) {
		error_ += "; " + msg;
		return;
	}
	status_ = Status::Error;
	error_ = msg;
}

Status Duel::advance() {
	if(status_ != Status::Continue)
		return status_;
	const int core_status = OCG_DuelProcess(duel_);
	uint32_t len = 0;
	const auto* buf = static_cast<const uint8_t*>(OCG_DuelGetMessage(duel_, &len));
	const std::vector<uint8_t> copy(buf, buf + len); // the core reuses its buffer
	bool prompted = false;
	auto_answered_ = false;
	const auto first_new_event = events_.size();
	try {
		prompted = parse(copy.data(), copy.size());
		// Instance ids are looked up where the cards are once this batch is processed.
		for(auto i = first_new_event; i < events_.size() && status_ != Status::Error; ++i) {
			auto& e = events_[i];
			switch(e.type) {
			case EventType::Move:
				fill_instance(e.card);
				e.from.instance = e.to.instance = e.card.instance;
				break;
			case EventType::Summon:
			case EventType::SpSummon:
			case EventType::FlipSummon:
			case EventType::Set:
			case EventType::Chaining:
				fill_instance(e.card);
				break;
			case EventType::Attack:
				fill_instance(e.from);
				fill_instance(e.to);
				break;
			default:
				break;
			}
		}
		if(prompted && status_ == Status::Continue) {
			for(auto& o : prompt_.options)
				if(o.card.code)
					fill_instance(o.card);
			fill_instance(prompt_.card);
		}
	} catch(const std::exception& e) {
		set_error(e.what());
	}
	if(status_ != Status::Continue)
		return status_; // error, or MSG_WIN (the core keeps going after it; hosts stop there)
	if(prompted)
		status_ = Status::Awaiting;
	else if(core_status == OCG_DUEL_STATUS_END)
		status_ = Status::Ended;
	else if(core_status == OCG_DUEL_STATUS_AWAITING && !auto_answered_)
		set_error("core is waiting for a response but sent no prompt");
	return status_;
}

std::vector<Event> Duel::take_events() {
	std::vector<Event> out;
	out.swap(events_);
	return out;
}

bool Duel::parse(const uint8_t* data, size_t size) {
	Reader outer(data, size);
	bool prompted = false;
	while(!outer.done() && status_ == Status::Continue) {
		const auto len = outer.get<uint32_t>();
		std::vector<uint8_t> body(len);
		for(auto& b : body)
			b = outer.get<uint8_t>();
		if(body.empty())
			fail("empty core message");
		if(parse_message(body[0], body.data() + 1, body.size() - 1))
			prompted = true;
	}
	return prompted;
}

// Returns true when the message is a prompt that now needs an answer.
bool Duel::parse_message(uint8_t type, const uint8_t* data, size_t size) {
	Reader r(data, size);
	Event ev;
	auto emit = [&](EventType t) {
		ev.type = t;
		events_.push_back(ev);
		return false;
	};
	auto begin = [&](PromptType t) {
		prompt_ = Prompt{};
		prompt_.type = t;
		prompt_.id = next_prompt_id_++;
		prompt_.player = r.get<uint8_t>();
		encoded_.clear();
	};
	auto add = [&](const std::string& action, CardRef card, std::vector<uint8_t> resp, uint64_t desc = 0) {
		Option o;
		o.action = action;
		o.card = card;
		o.desc = desc;
		prompt_.options.push_back(o);
		encoded_.push_back(std::move(resp));
	};
	switch(type) {
	case MSG_RETRY:
		if(prompt_.id == 0)
			fail("core sent MSG_RETRY before any prompt");
		prompt_.id = next_prompt_id_++; // same question again; the old id is now stale
		prompt_.retry = true;
		return true;
	case MSG_WIN:
		ev.player = r.get<uint8_t>();
		ev.value = r.get<uint8_t>();
		winner_ = ev.player;
		win_reason_ = ev.value;
		status_ = Status::Ended;
		return emit(EventType::Win);
	case MSG_NEW_TURN:
		ev.player = r.get<uint8_t>();
		return emit(EventType::NewTurn);
	case MSG_NEW_PHASE:
		ev.value = r.get<uint16_t>();
		return emit(EventType::NewPhase);
	case MSG_DRAW: {
		ev.player = r.get<uint8_t>();
		const auto n = r.get<uint32_t>();
		for(uint32_t i = 0; i < n; ++i) {
			ev.codes.push_back(r.get<uint32_t>() & 0x7fffffff);
			r.get<uint32_t>();
		}
		return emit(EventType::Draw);
	}
	case MSG_MOVE: {
		const auto code = r.get<uint32_t>();
		ev.from = read_loc(r, code);
		ev.to = read_loc(r, code);
		ev.card = ev.to;
		ev.reason = r.get<uint32_t>();
		return emit(EventType::Move);
	}
	case MSG_SUMMONING:
	case MSG_SPSUMMONING:
	case MSG_FLIPSUMMONING:
	case MSG_SET: {
		const auto code = r.get<uint32_t>();
		ev.card = read_loc(r, code);
		return emit(type == MSG_SUMMONING ? EventType::Summon : type == MSG_SPSUMMONING ? EventType::SpSummon
		            : type == MSG_FLIPSUMMONING ? EventType::FlipSummon : EventType::Set);
	}
	case MSG_CHAINING: {
		const auto code = r.get<uint32_t>();
		ev.card = read_loc(r, code);
		r.skip(1 + 1 + 4 + 8); // triggering controller/location/sequence, description
		ev.value = r.get<uint32_t>();
		chain_.push_back(code);
		return emit(EventType::Chaining);
	}
	case MSG_CHAIN_SOLVING:
		ev.value = r.get<uint8_t>();
		if(ev.value == 0 || ev.value > chain_.size())
			fail("CHAIN_SOLVING for unknown link " + std::to_string(ev.value));
		ev.card.code = chain_[ev.value - 1];
		return emit(EventType::ChainSolving);
	case MSG_CHAIN_NEGATED:
	case MSG_CHAIN_DISABLED:
		ev.value = r.get<uint8_t>();
		return emit(type == MSG_CHAIN_NEGATED ? EventType::ChainNegated : EventType::ChainDisabled);
	case MSG_CHAIN_END:
		chain_.clear();
		return emit(EventType::ChainEnd);
	case MSG_DAMAGE:
	case MSG_RECOVER:
	case MSG_PAY_LPCOST:
		ev.player = r.get<uint8_t>();
		ev.value = r.get<uint32_t>();
		return emit(type == MSG_DAMAGE ? EventType::Damage : type == MSG_RECOVER ? EventType::Recover : EventType::PayLp);
	case MSG_ATTACK:
		ev.from = read_loc(r);
		ev.to = read_loc(r);
		return emit(EventType::Attack);

	case MSG_SELECT_IDLECMD: {
		begin(PromptType::Idle);
		static const char* const verbs[] = {"summon", "spsummon", "repos", "mset", "sset", "activate"};
		for(int32_t t = 0; t < 6; ++t) {
			const auto n = r.get<uint32_t>();
			for(int32_t i = 0; i < static_cast<int32_t>(n); ++i) {
				const auto card = read_short(r, t != 2);
				uint64_t desc = 0;
				if(t == 5) {
					desc = r.get<uint64_t>();
					r.get<uint8_t>();
				}
				add(verbs[t], card, bytes<int32_t>((i << 16) | t), desc);
			}
		}
		if(r.get<uint8_t>())
			add("battle", {}, bytes<int32_t>(6));
		if(r.get<uint8_t>())
			add("end", {}, bytes<int32_t>(7));
		if(r.get<uint8_t>())
			add("shuffle", {}, bytes<int32_t>(8));
		return true;
	}
	case MSG_SELECT_BATTLECMD: {
		begin(PromptType::Battle);
		const auto acts = r.get<uint32_t>();
		for(int32_t i = 0; i < static_cast<int32_t>(acts); ++i) {
			const auto card = read_short(r, true);
			const auto desc = r.get<uint64_t>();
			r.get<uint8_t>();
			add("activate", card, bytes<int32_t>(i << 16), desc);
		}
		const auto attackers = r.get<uint32_t>();
		for(int32_t i = 0; i < static_cast<int32_t>(attackers); ++i) {
			const auto card = read_short(r, false);
			r.get<uint8_t>(); // can attack directly
			add("attack", card, bytes<int32_t>((i << 16) | 1));
		}
		if(r.get<uint8_t>())
			add("main2", {}, bytes<int32_t>(2));
		if(r.get<uint8_t>())
			add("end", {}, bytes<int32_t>(3));
		return true;
	}
	case MSG_SELECT_EFFECTYN:
	case MSG_SELECT_YESNO:
		begin(type == MSG_SELECT_EFFECTYN ? PromptType::EffectYesNo : PromptType::YesNo);
		if(type == MSG_SELECT_EFFECTYN) {
			const auto code = r.get<uint32_t>();
			prompt_.card = read_loc(r, code);
		}
		prompt_.desc = r.get<uint64_t>();
		add("yes", prompt_.card, bytes<int32_t>(1));
		add("no", prompt_.card, bytes<int32_t>(0));
		return true;
	case MSG_SELECT_OPTION: {
		begin(PromptType::Option);
		const auto n = r.get<uint8_t>();
		for(int32_t i = 0; i < n; ++i)
			add("option", {}, bytes<int32_t>(i), r.get<uint64_t>());
		return true;
	}
	case MSG_SELECT_CHAIN: {
		const auto player = r.get<uint8_t>();
		r.get<uint8_t>(); // spe_count
		const bool forced = r.get<uint8_t>();
		r.get<uint32_t>();
		r.get<uint32_t>();
		const auto n = r.get<uint32_t>();
		if(n == 0 && !forced) {
			// Passing is the only legal answer, so there is nothing to ask.
			const int32_t pass = -1;
			OCG_DuelSetResponse(duel_, &pass, sizeof(pass));
			auto_answered_ = true;
			return false;
		}
		prompt_ = Prompt{};
		prompt_.type = PromptType::Chain;
		prompt_.id = next_prompt_id_++;
		prompt_.player = player;
		prompt_.forced = forced;
		encoded_.clear();
		for(int32_t i = 0; i < static_cast<int32_t>(n); ++i) {
			const auto code = r.get<uint32_t>();
			const auto card = read_loc(r, code);
			const auto desc = r.get<uint64_t>();
			r.get<uint8_t>();
			add("activate", card, bytes<int32_t>(i), desc);
		}
		if(!forced)
			add("pass", {}, bytes<int32_t>(-1));
		return true;
	}
	case MSG_SELECT_CARD:
	case MSG_SELECT_TRIBUTE: {
		begin(type == MSG_SELECT_CARD ? PromptType::SelectCard : PromptType::SelectTribute);
		prompt_.cancelable = r.get<uint8_t>();
		prompt_.min = r.get<uint32_t>();
		prompt_.max = r.get<uint32_t>();
		const auto n = r.get<uint32_t>();
		for(uint32_t i = 0; i < n; ++i) {
			const auto code = r.get<uint32_t>();
			CardRef card;
			uint32_t param = 0;
			if(type == MSG_SELECT_CARD) {
				card = read_loc(r, code);
			} else {
				card.code = code;
				card.controller = r.get<uint8_t>();
				card.location = r.get<uint8_t>();
				card.sequence = r.get<uint32_t>();
				param = r.get<uint8_t>();
			}
			add("card", card, {});
			prompt_.options.back().param = param;
		}
		return true;
	}
	case MSG_SELECT_UNSELECT_CARD: {
		begin(PromptType::SelectUnselect);
		const bool finishable = r.get<uint8_t>();
		const bool cancelable = r.get<uint8_t>();
		prompt_.min = r.get<uint32_t>();
		prompt_.max = r.get<uint32_t>();
		int32_t idx = 0;
		for(const char* action : {"select", "unselect"}) {
			const auto n = r.get<uint32_t>();
			for(uint32_t i = 0; i < n; ++i, ++idx) {
				const auto code = r.get<uint32_t>();
				auto resp = bytes<int32_t>(1);
				append<int32_t>(resp, idx);
				add(action, read_loc(r, code), resp);
			}
		}
		if(finishable)
			add("finish", {}, bytes<int32_t>(-1));
		if(cancelable)
			add("cancel", {}, bytes<int32_t>(-1));
		prompt_.min = prompt_.max = 1;
		return true;
	}
	case MSG_SELECT_PLACE:
	case MSG_SELECT_DISFIELD: {
		begin(PromptType::Place);
		prompt_.min = prompt_.max = r.get<uint8_t>();
		const auto flag = r.get<uint32_t>(); // set bits are unavailable
		for(uint32_t bit = 0; bit < 32; ++bit) {
			if((flag & (1u << bit)) || bit % 16 == 7) // bit 7 of each half has no monster zone
				continue;
			CardRef zone;
			zone.controller = bit < 16 ? prompt_.player : 1 - prompt_.player;
			zone.location = (bit % 16) < 8 ? LOCATION_MZONE : LOCATION_SZONE;
			zone.sequence = bit % 8;
			add("zone", zone, {});
		}
		return true;
	}
	case MSG_SELECT_POSITION: {
		begin(PromptType::Position);
		prompt_.card.code = r.get<uint32_t>();
		const auto allowed = r.get<uint8_t>();
		static const std::pair<const char*, int32_t> positions[] = {
			{"fu_atk", POS_FACEUP_ATTACK}, {"fd_atk", POS_FACEDOWN_ATTACK},
			{"fu_def", POS_FACEUP_DEFENSE}, {"fd_def", POS_FACEDOWN_DEFENSE}};
		for(const auto& [name, pos] : positions)
			if(allowed & pos)
				add(name, prompt_.card, bytes<int32_t>(pos));
		return true;
	}
	case MSG_SORT_CHAIN:
	case MSG_SORT_CARD: {
		begin(PromptType::Sort);
		const auto n = r.get<uint32_t>();
		for(uint32_t i = 0; i < n; ++i) {
			CardRef card;
			card.code = r.get<uint32_t>();
			card.controller = r.get<uint8_t>();
			card.location = static_cast<uint8_t>(r.get<uint32_t>());
			card.sequence = r.get<uint32_t>();
			add("card", card, {});
		}
		prompt_.min = prompt_.max = 0;
		return true;
	}
	case MSG_SELECT_COUNTER: {
		begin(PromptType::Counter);
		prompt_.desc = r.get<uint16_t>(); // counter type
		prompt_.value = r.get<uint16_t>();
		const auto n = r.get<uint32_t>();
		for(uint32_t i = 0; i < n; ++i) {
			const auto card = read_short(r, false);
			add("card", card, {});
			prompt_.options.back().param = r.get<uint16_t>();
		}
		return true;
	}
	case MSG_SELECT_SUM: {
		begin(PromptType::SelectSum);
		prompt_.at_least = r.get<uint8_t>();
		prompt_.value = r.get<uint32_t>();
		prompt_.min = r.get<uint32_t>();
		prompt_.max = r.get<uint32_t>();
		for(const char* action : {"must", "card"}) {
			const auto n = r.get<uint32_t>();
			for(uint32_t i = 0; i < n; ++i) {
				const auto code = r.get<uint32_t>();
				add(action, read_loc(r, code), {});
				prompt_.options.back().param = r.get<uint32_t>();
			}
		}
		return true;
	}
	case MSG_ANNOUNCE_RACE:
	case MSG_ANNOUNCE_ATTRIB: {
		const bool race = type == MSG_ANNOUNCE_RACE;
		begin(race ? PromptType::AnnounceRace : PromptType::AnnounceAttribute);
		prompt_.value = prompt_.min = prompt_.max = r.get<uint8_t>();
		const uint64_t available = race ? r.get<uint64_t>() : r.get<uint32_t>();
		for(int bit = 0; bit < 64; ++bit)
			if(available & (1ULL << bit))
				add(race ? "race" : "attribute", {}, {}, 1ULL << bit);
		return true;
	}
	case MSG_ANNOUNCE_NUMBER: {
		begin(PromptType::AnnounceNumber);
		const auto n = r.get<uint8_t>();
		for(int32_t i = 0; i < n; ++i)
			add("number", {}, bytes<int32_t>(i), r.get<uint64_t>());
		return true;
	}
	case MSG_ANNOUNCE_CARD: {
		begin(PromptType::AnnounceCard);
		const auto n = r.get<uint8_t>();
		for(uint32_t i = 0; i < n; ++i)
			prompt_.filter.push_back(r.get<uint64_t>());
		return true;
	}
	case MSG_ROCK_PAPER_SCISSORS:
		begin(PromptType::RockPaperScissors);
		add("scissors", {}, bytes<int32_t>(1));
		add("rock", {}, bytes<int32_t>(2));
		add("paper", {}, bytes<int32_t>(3));
		return true;
	default:
		return false; // informational message no host needs yet
	}
}

bool Duel::submit(uint64_t prompt_id, const std::vector<uint32_t>& picks, std::string& error) {
	if(status_ != Status::Awaiting) {
		error = "no prompt is waiting for an answer";
		return false;
	}
	if(prompt_id != prompt_.id) {
		error = "stale prompt id " + std::to_string(prompt_id) + " (current is " + std::to_string(prompt_.id) + ")";
		return false;
	}
	auto reject = [&error](const std::string& msg) {
		error = msg;
		return false;
	};
	auto send = [this](const std::vector<uint8_t>& resp) {
		OCG_DuelSetResponse(duel_, resp.data(), static_cast<uint32_t>(resp.size()));
		status_ = Status::Continue;
		return true;
	};
	if(prompt_.type == PromptType::AnnounceCard) {
		if(picks.size() != 1)
			return reject("declare exactly one card code");
		if(!content_.card(picks[0]).found)
			return reject("unknown card code " + std::to_string(picks[0]));
		return send(bytes<int32_t>(static_cast<int32_t>(picks[0])));
	}
	const auto n = prompt_.options.size();
	std::set<uint32_t> seen;
	for(auto p : picks) {
		if(p >= n)
			return reject("option index " + std::to_string(p) + " out of range (0.." + std::to_string(n) + ")");
		if(!seen.insert(p).second && prompt_.type != PromptType::Counter)
			return reject("option index " + std::to_string(p) + " picked twice");
	}
	auto card_list = [&](uint32_t offset) {
		auto resp = bytes<int32_t>(0);
		append<uint32_t>(resp, static_cast<uint32_t>(picks.size()));
		for(auto p : picks)
			append<uint32_t>(resp, p - offset);
		return resp;
	};
	auto count_error = [&](uint32_t lo, uint32_t hi) {
		return "picked " + std::to_string(picks.size()) + ", need " + std::to_string(lo) + ".." + std::to_string(hi);
	};
	std::vector<uint8_t> resp;
	switch(prompt_.type) {
	case PromptType::SelectCard:
		if(picks.empty() && prompt_.cancelable)
			return send(bytes<int32_t>(-1));
		if(picks.size() < prompt_.min || picks.size() > prompt_.max)
			return reject(count_error(prompt_.min, prompt_.max));
		resp = card_list(0);
		break;
	case PromptType::SelectTribute:
		// min/max here count release value (a card may count as 2); the core checks the total.
		if(picks.empty() && prompt_.cancelable)
			return send(bytes<int32_t>(-1));
		if(picks.empty() || picks.size() > prompt_.max)
			return reject(count_error(1, prompt_.max));
		resp = card_list(0);
		break;
	case PromptType::SelectSum: {
		uint32_t must = 0;
		while(must < n && prompt_.options[must].action == "must")
			++must;
		for(auto p : picks)
			if(p < must)
				return reject("option " + std::to_string(p) + " is always included and cannot be picked");
		if(!prompt_.at_least && (picks.size() < prompt_.min || picks.size() > prompt_.max))
			return reject(count_error(prompt_.min, prompt_.max));
		resp = card_list(must); // the core indexes only the pickable cards
		break;
	}
	case PromptType::Counter:
		if(picks.size() != prompt_.value)
			return reject("remove exactly " + std::to_string(prompt_.value) + " counter(s), picked " + std::to_string(picks.size()));
		for(uint32_t i = 0; i < n; ++i)
			append<int16_t>(resp, static_cast<int16_t>(std::count(picks.begin(), picks.end(), i)));
		break;
	case PromptType::AnnounceRace:
	case PromptType::AnnounceAttribute: {
		if(picks.size() != prompt_.value)
			return reject("declare exactly " + std::to_string(prompt_.value) + ", picked " + std::to_string(picks.size()));
		uint64_t mask = 0;
		for(auto p : picks)
			mask |= prompt_.options[p].desc;
		resp = prompt_.type == PromptType::AnnounceRace ? bytes<uint64_t>(mask) : bytes<uint32_t>(static_cast<uint32_t>(mask));
		break;
	}
	case PromptType::Place:
		if(picks.size() != prompt_.min)
			return reject("pick exactly " + std::to_string(prompt_.min) + " zone(s)");
		for(auto p : picks) {
			const auto& zone = prompt_.options[p].card;
			append<uint8_t>(resp, zone.controller);
			append<uint8_t>(resp, zone.location);
			append<uint8_t>(resp, static_cast<uint8_t>(zone.sequence));
		}
		break;
	case PromptType::Sort:
		if(picks.empty())
			return send(bytes<int8_t>(-1));
		if(picks.size() != n)
			return reject("order all " + std::to_string(n) + " cards, or submit none for the default order");
		resp.resize(n);
		for(uint32_t rank = 0; rank < n; ++rank) // the core wants each card's rank, 0 = first/top
			resp[picks[rank]] = static_cast<uint8_t>(rank);
		break;
	default:
		if(picks.size() != 1)
			return reject("this prompt takes exactly one option");
		resp = encoded_[picks[0]];
	}
	return send(resp);
}

uint32_t Duel::lp(uint8_t player) {
	uint32_t len = 0;
	const auto* buf = static_cast<const uint8_t*>(OCG_DuelQueryField(duel_, &len));
	Reader r(buf, len);
	r.get<uint32_t>(); // duel options
	for(uint8_t p = 0;; ++p) {
		const auto value = r.get<uint32_t>();
		if(p == (player & 1))
			return value;
		for(int zone = 0; zone < 7 + 8; ++zone)
			if(r.get<uint8_t>()) {
				r.get<uint8_t>();
				r.get<uint32_t>();
			}
		r.skip(6 * sizeof(uint32_t));
	}
}

uint32_t Duel::count(uint8_t player, uint32_t location) {
	return OCG_DuelQueryCount(duel_, player & 1, location);
}

namespace {
constexpr uint32_t kCardQuery = QUERY_CODE | QUERY_POSITION | QUERY_YGOPVE_CARDID;

// One card's fields: [u16 size][u32 flag][payload] ... ending in QUERY_END. `size` is
// the already-read size of the first field; 0 means an empty zone.
void read_card_fields(Reader& r, uint16_t size, CardRef& c) {
	for(; size != 0; size = r.get<uint16_t>()) {
		const auto flag = r.get<uint32_t>();
		if(flag == QUERY_END)
			return;
		if(flag == QUERY_CODE)
			c.code = r.get<uint32_t>();
		else if(flag == QUERY_POSITION)
			c.position = r.get<uint32_t>();
		else if(flag == QUERY_YGOPVE_CARDID)
			c.instance = r.get<uint32_t>();
		else
			r.skip(size - sizeof(uint32_t));
	}
}
} // namespace

std::vector<CardRef> Duel::cards(uint8_t player, uint32_t location) {
	OCG_QueryInfo info{kCardQuery, static_cast<uint8_t>(player & 1), location, 0, 0};
	uint32_t len = 0;
	const auto* buf = static_cast<const uint8_t*>(OCG_DuelQueryLocation(duel_, &len, &info));
	std::vector<CardRef> out;
	if(len < sizeof(uint32_t))
		return out;
	Reader r(buf + sizeof(uint32_t), len - sizeof(uint32_t));
	for(uint32_t seq = 0; !r.done(); ++seq) {
		CardRef c;
		c.controller = player & 1;
		c.location = static_cast<uint8_t>(location);
		c.sequence = seq;
		read_card_fields(r, r.get<uint16_t>(), c);
		out.push_back(c);
	}
	return out;
}

void Duel::fill_instance(CardRef& ref) {
	if(!ref.location || (ref.location & LOCATION_OVERLAY))
		return; // zones, code-only references, xyz materials
	OCG_QueryInfo info{kCardQuery, ref.controller, ref.location, ref.sequence, 0};
	uint32_t len = 0;
	const auto* buf = static_cast<const uint8_t*>(OCG_DuelQuery(duel_, &len, &info));
	if(!buf || len == 0)
		return;
	Reader r(buf, len);
	CardRef found;
	read_card_fields(r, r.get<uint16_t>(), found);
	// ponytail: if the card moved again within the same batch, another card may sit there now;
	// the code check catches most of those, a different copy of the same card would not be caught.
	if(!ref.code || found.code == ref.code)
		ref.instance = found.instance;
}

const CardOrigin* Duel::origin(uint32_t instance) const {
	auto it = origins_.find(instance);
	return it == origins_.end() ? nullptr : &it->second;
}

// ------------------------------------------------------------------ helpers

std::pair<int, int> core_version() {
	int major = 0, minor = 0;
	OCG_GetVersion(&major, &minor);
	if(major != OCG_VERSION_MAJOR)
		fail("ocgcore API " + std::to_string(major) + "." + std::to_string(minor) + " does not match headers " +
		     std::to_string(OCG_VERSION_MAJOR) + "." + std::to_string(OCG_VERSION_MINOR));
	return {major, minor};
}

const char* to_string(PromptType type) {
	switch(type) {
	case PromptType::Idle: return "SELECT_IDLECMD";
	case PromptType::Battle: return "SELECT_BATTLECMD";
	case PromptType::EffectYesNo: return "SELECT_EFFECTYN";
	case PromptType::YesNo: return "SELECT_YESNO";
	case PromptType::Option: return "SELECT_OPTION";
	case PromptType::Chain: return "SELECT_CHAIN";
	case PromptType::SelectCard: return "SELECT_CARD";
	case PromptType::SelectTribute: return "SELECT_TRIBUTE";
	case PromptType::SelectUnselect: return "SELECT_UNSELECT_CARD";
	case PromptType::SelectSum: return "SELECT_SUM";
	case PromptType::Counter: return "SELECT_COUNTER";
	case PromptType::Place: return "SELECT_PLACE";
	case PromptType::Position: return "SELECT_POSITION";
	case PromptType::Sort: return "SORT_CARD";
	case PromptType::AnnounceRace: return "ANNOUNCE_RACE";
	case PromptType::AnnounceAttribute: return "ANNOUNCE_ATTRIB";
	case PromptType::AnnounceNumber: return "ANNOUNCE_NUMBER";
	case PromptType::AnnounceCard: return "ANNOUNCE_CARD";
	case PromptType::RockPaperScissors: return "ROCK_PAPER_SCISSORS";
	}
	return "?";
}

std::string where(const CardRef& ref) {
	return "p" + std::to_string(ref.controller) + "." + loc_name(ref.location) + "[" + std::to_string(ref.sequence) + "]" +
	       (ref.instance ? "#" + std::to_string(ref.instance) : std::string());
}

uint32_t parse_location(const std::string& name) {
	static const std::map<std::string, uint32_t> locs = {
		{"deck", LOCATION_DECK}, {"hand", LOCATION_HAND}, {"mzone", LOCATION_MZONE},
		{"szone", LOCATION_SZONE}, {"grave", LOCATION_GRAVE}, {"removed", LOCATION_REMOVED},
		{"extra", LOCATION_EXTRA}};
	auto it = locs.find(name);
	return it == locs.end() ? 0 : it->second;
}

std::string describe(Content& content, const Event& e) {
	const auto p = "p" + std::to_string(e.player);
	switch(e.type) {
	case EventType::NewTurn: return "\n--- new turn (" + p + ")";
	case EventType::NewPhase: return "  phase " + phase_name(e.value);
	case EventType::Draw: {
		std::string s = "  " + p + " draws";
		for(auto code : e.codes)
			s += " " + content.label(code);
		return s;
	}
	case EventType::Move: {
		char reason[16];
		std::snprintf(reason, sizeof(reason), "0x%x", e.reason);
		return "  move " + content.label(e.card.code) + " " + where(e.from) + " -> " + where(e.to) + " reason=" + reason;
	}
	case EventType::Summon: return "  normal summon " + content.label(e.card.code) + " at " + where(e.card);
	case EventType::SpSummon: return "  special summon " + content.label(e.card.code) + " at " + where(e.card);
	case EventType::FlipSummon: return "  flip summon " + content.label(e.card.code) + " at " + where(e.card);
	case EventType::Set: return "  set " + content.label(e.card.code) + " at " + where(e.card);
	case EventType::Chaining: return "  CHAIN LINK " + std::to_string(e.value) + ": " + content.label(e.card.code) + " from " + where(e.card);
	case EventType::ChainSolving: return "  resolve link " + std::to_string(e.value) + ": " + content.label(e.card.code);
	case EventType::ChainEnd: return "  chain end";
	case EventType::ChainNegated: return "  link " + std::to_string(e.value) + " activation negated";
	case EventType::ChainDisabled: return "  link " + std::to_string(e.value) + " effect negated";
	case EventType::Damage: return "  " + p + " takes damage " + std::to_string(e.value);
	case EventType::Recover: return "  " + p + " recovers " + std::to_string(e.value);
	case EventType::PayLp: return "  " + p + " pays LP " + std::to_string(e.value);
	case EventType::Attack: return "  attack " + where(e.from) + " -> " + (e.to.location ? where(e.to) : std::string("direct"));
	case EventType::Win:
		return "WIN player=" + std::to_string(e.player) + " reason=" + std::to_string(e.value) +
		       (e.value == 1 ? " (LP)" : e.value == 2 ? " (deck-out)" : " (card effect/other)");
	}
	return "?";
}

std::string describe(Content& content, const Prompt& pr) {
	std::string s = "? p" + std::to_string(pr.player) + " " + to_string(pr.type);
	if(pr.retry)
		s += " (retry: previous answer rejected)";
	if(pr.type == PromptType::SelectCard || pr.type == PromptType::SelectTribute || pr.type == PromptType::Place ||
	   (pr.type == PromptType::SelectSum && !pr.at_least))
		s += " pick " + std::to_string(pr.min) + "-" + std::to_string(pr.max);
	if(pr.type == PromptType::SelectSum)
		s += std::string(pr.at_least ? " reaching" : " summing to") + " " + std::to_string(pr.value);
	if(pr.type == PromptType::Counter || pr.type == PromptType::AnnounceRace || pr.type == PromptType::AnnounceAttribute)
		s += " x" + std::to_string(pr.value);
	if(pr.type == PromptType::AnnounceCard)
		s += " (submit a card code; filter of " + std::to_string(pr.filter.size()) + " opcodes)";
	if(pr.forced)
		s += " (forced)";
	if(pr.type == PromptType::EffectYesNo || pr.type == PromptType::Position)
		s += " for " + content.label(pr.card.code);
	s += ":";
	for(size_t i = 0; i < pr.options.size(); ++i) {
		const auto& o = pr.options[i];
		s += " [" + std::to_string(i) + "] " + o.action;
		if(o.action == "zone")
			s += " " + where(o.card);
		else if(o.card.code)
			s += " " + content.label(o.card.code) + (o.card.location ? "@" + where(o.card) : std::string());
		if(o.action == "race" || o.action == "attribute") {
			char hex[24];
			std::snprintf(hex, sizeof(hex), " 0x%llx", static_cast<unsigned long long>(o.desc));
			s += hex;
		} else if(o.action == "number") {
			s += " " + std::to_string(o.desc);
		}
		if(pr.type == PromptType::SelectSum || pr.type == PromptType::Counter)
			s += " (" + std::to_string(o.param) + ")";
	}
	return s;
}

} // namespace battle
