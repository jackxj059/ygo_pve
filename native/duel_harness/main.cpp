// Headless duel runner: a host of the battle module that answers prompts from a
// scenario file. The defaults below (zone, position, passing unscripted chain
// windows) are this test layer's choices, not battle rules.
// Any unexpected prompt, rejected answer, core/script error or failed
// expectation ends the run with a non-zero exit code.
#include <algorithm>
#include <cstdio>
#include <deque>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "battle.h"
#include "deck.h"
#include "ocgapi_constants.h"

namespace {

[[noreturn]] void fail(const std::string& msg) { throw std::runtime_error(msg); }

uint32_t to_u32(const std::string& s) { return static_cast<uint32_t>(std::stoul(s)); }

struct Action {
	int line = 0;
	int player = -1; // -1 expectation, -2 stop
	std::string verb;
	std::vector<std::string> args;
	std::string text;
};

struct Scenario {
	battle::DuelConfig config;
	std::deque<Action> actions;
	bool script_ai[2] = {}; // enemy_ai P: the enemy scripts answer every prompt of player P
};

uint32_t location_arg(const std::string& s) {
	if(auto loc = battle::parse_location(s))
		return loc;
	fail("unknown location '" + s + "'");
}

Scenario load_scenario(const std::string& path) {
	std::ifstream in(path);
	if(!in)
		fail("cannot open scenario " + path);
	Scenario sc;
	auto& cfg = sc.config;
	uint32_t next_zone[2][2] = {}; // [player][mzone, szone]: next free slot for field placements
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
					cfg.seed[i] = std::stoull(tok[i + 1]);
			} else if(kw == "lp" && setup && tok.size() == 3) {
				cfg.players[to_u32(tok[1]) & 1].lp = to_u32(tok[2]);
			} else if(kw == "start_draw" && setup && tok.size() == 3) {
				cfg.players[to_u32(tok[1]) & 1].start_draw = to_u32(tok[2]);
			} else if(kw == "ap" && setup && tok.size() == 4) {
				auto& ap = cfg.players[to_u32(tok[1]) & 1].ap;
				ap.enabled = true;
				ap.max = to_u32(tok[2]);
				ap.initial = to_u32(tok[3]);
			} else if(kw == "ap_cost" && setup && tok.size() == 4) {
				static const std::set<std::string> kinds = {"summon", "spsummon", "set", "activate", "attack", "repos"};
				if(!kinds.count(tok[2]))
					fail("unknown AP cost kind '" + tok[2] + "'");
				cfg.players[to_u32(tok[1]) & 1].ap.costs[tok[2]] = to_u32(tok[3]);
			} else if(kw == "draw_per_turn" && setup && tok.size() == 2) {
				cfg.players[0].draw_per_turn = cfg.players[1].draw_per_turn = to_u32(tok[1]);
			} else if(kw == "enemy_ai" && setup && tok.size() == 2) {
				sc.script_ai[to_u32(tok[1]) & 1] = true;
			} else if(kw == "draw_per_turn" && setup && tok.size() == 3) {
				cfg.players[to_u32(tok[1]) & 1].draw_per_turn = to_u32(tok[2]);
			} else if(kw == "deck" && setup && tok.size() == 3) {
				const auto deck = battle::load_ydk(tok[2]);
				auto& p = cfg.players[to_u32(tok[1]) & 1];
				p.main = deck.main;
				p.extra = deck.extra; // side deck stays out of the duel
				std::printf("== p%s deck %s: main %zu, extra %zu, side %zu\n", tok[1].c_str(), tok[2].c_str(), deck.main.size(), deck.extra.size(), deck.side.size());
			} else if(kw == "card" && setup && (tok.size() == 4 || tok.size() == 5)) {
				const auto player = static_cast<uint8_t>(to_u32(tok[1]) & 1);
				const auto loc = location_arg(tok[2]);
				const bool field = loc == LOCATION_MZONE || loc == LOCATION_SZONE;
				uint32_t copies = 1, position = 0;
				if(tok.size() == 5 && field) {
					static const std::map<std::string, uint32_t> positions = {
						{"fu_atk", POS_FACEUP_ATTACK}, {"fu_def", POS_FACEUP_DEFENSE}, {"fd_def", POS_FACEDOWN_DEFENSE}, {"fd", POS_FACEDOWN}};
					auto it = positions.find(tok[4]);
					if(it == positions.end())
						fail("expected a position (fu_atk/fu_def/fd_def/fd) for a field card");
					position = it->second;
				} else if(tok.size() == 5) {
					if(tok[4].empty() || tok[4][0] != 'x')
						fail("expected copy count like x10");
					copies = to_u32(tok[4].substr(1));
				}
				for(uint32_t i = 0; i < copies; ++i) {
					battle::Placement pl{player, loc, to_u32(tok[3])};
					if(field) {
						pl.sequence = next_zone[player][loc == LOCATION_SZONE]++;
						pl.position = position;
					}
					cfg.placements.push_back(pl);
				}
			} else if(kw == "expect" && tok.size() >= 2) {
				sc.actions.push_back({line_no, -1, tok[1], {tok.begin() + 2, tok.end()}, text});
			} else if(kw == "stop" && tok.size() == 1) {
				sc.actions.push_back({line_no, -2, kw, {}, text});
			} else if((kw == "0" || kw == "1") && tok.size() >= 2) {
				sc.actions.push_back({line_no, kw[0] - '0', tok[1], {tok.begin() + 2, tok.end()}, text});
			} else {
				fail("unrecognised line (setup lines must come before actions)");
			}
		} catch(const std::exception& e) {
			fail(path + ":" + std::to_string(line_no) + ": " + e.what());
		}
	}
	return sc;
}

class Runner {
public:
	Runner(Scenario sc, battle::Content& content) : sc_(std::move(sc)), content_(content) {}

	void run() {
		battle::Duel duel(content_, sc_.config);
		duel_ = &duel;
		std::printf("== duel created\n");
		bool stopped = false;
		for(int steps = 0;; ++steps) {
			if(steps > 200000)
				fail("duel did not settle after 200000 steps (stuck loop?)");
			const auto status = duel.advance();
			for(const auto& e : duel.take_events())
				on_event(e);
			if(status == battle::Status::Continue)
				continue;
			if(status == battle::Status::Error)
				fail(duel.error());
			if(status == battle::Status::Ended)
				break;
			const auto& pr = *duel.prompt();
			if(pr.retry) {
				if(sc_.actions.empty() || sc_.actions.front().player != -1 || sc_.actions.front().verb != "retry")
					fail("core rejected the last response (MSG_RETRY)");
				std::printf("  ok: %s\n", sc_.actions.front().text.c_str());
				sc_.actions.pop_front();
			}
			if(next_player_action() && next_player_action()->player == -2 && !answered_by_default(pr)) {
				run_expectations();
				sc_.actions.pop_front();
				std::printf("== scenario stopped at: %s\n", battle::describe(content_, pr).c_str());
				stopped = true;
				break;
			}
			std::printf("%s\n", battle::describe(content_, pr).c_str());
			std::vector<uint32_t> picks;
			if(sc_.script_ai[pr.player & 1]) {
				if(pr.retry)
					fail("the core rejected the enemy scripts' previous answer");
				std::string error;
				if(!duel.script_decide(picks, error))
					fail("enemy decision failed: " + error);
				if(picks.size() == 1 && picks[0] < pr.options.size())
					last_choice_ = pr.options[picks[0]].card.code;
				std::string shown;
				for(auto i : picks)
					shown += " " + (i < pr.options.size() ? pr.options[i].action + (pr.options[i].card.code ? " " + std::to_string(pr.options[i].card.code) : "") : std::to_string(i)) + ";";
				std::printf("  > enemy script:%s\n", shown.empty() ? " (default order)" : shown.c_str());
			} else {
				picks = decide(pr);
			}
			std::string error;
			if(!duel.submit(pr.id, picks, error))
				fail("battle module rejected the answer: " + error);
		}
		if(!stopped) {
			std::printf("== duel ended\n");
			run_expectations();
			if(duel.winner() < 0)
				fail("duel ended without MSG_WIN");
		}
		if(!sc_.actions.empty())
			fail("scenario line " + std::to_string(sc_.actions.front().line) + " was never used: " + sc_.actions.front().text);
	}

private:
	void on_event(const battle::Event& e) {
		std::string s = battle::describe(content_, e);
		if(e.type == battle::EventType::Chaining) {
			s += last_choice_ == e.card.code ? " (chosen by player)" : " (activated without a player prompt)";
			last_choice_ = 0;
			resolved_.clear();
		} else if(e.type == battle::EventType::ChainSolving) {
			resolved_.push_back(e.card.code);
		} else if(e.type == battle::EventType::ChainEnd) {
			last_chain_ = resolved_;
		} else if(e.type == battle::EventType::Move) {
			last_move_reason_[e.card.code] = e.reason;
		} else if(e.type == battle::EventType::Hp) {
			last_hp_[e.card.code] = e.card.instance;
		}
		std::printf("%s\n", s.c_str());
	}

	std::vector<uint32_t> decide(const battle::Prompt& pr) {
		using battle::PromptType;
		const auto p = pr.player;
		const char* name = battle::to_string(pr.type);
		switch(pr.type) {
		case PromptType::Idle:
		case PromptType::Battle: {
			const auto act = take(p, pr.type == PromptType::Idle ? "idle" : "battle", name);
			const auto what = arg(act, 0);
			const bool needs_card = what == "summon" || what == "spsummon" || what == "repos" || what == "mset" ||
			                        what == "sset" || what == "activate" || what == "attack";
			const auto idx = needs_card ? pick(pr, what, to_u32(arg(act, 1)), {}, act) : pick_action(pr, what, act);
			if(what == "activate")
				last_choice_ = pr.options[idx].card.code;
			return answer({idx}, act.text);
		}
		case PromptType::EffectYesNo:
		case PromptType::YesNo: {
			const auto act = take(p, "yesno", name);
			const auto idx = pick_action(pr, arg(act, 0), act);
			if(pr.options[idx].action == "yes")
				last_choice_ = pr.card.code;
			return answer({idx}, act.text);
		}
		case PromptType::Option: {
			const auto act = take(p, "option", name);
			const auto idx = to_u32(arg(act, 0));
			if(idx >= pr.options.size())
				fail("line " + std::to_string(act.line) + ": option index out of range");
			return answer({idx}, act.text);
		}
		case PromptType::SelectCard:
		case PromptType::SelectTribute:
		case PromptType::SelectSum: {
			const auto act = take(p, "select", name);
			std::vector<uint32_t> picks;
			for(const auto& code : act.args)
				picks.push_back(pick(pr, "card", to_u32(code), picks, act));
			return answer(picks, act.text);
		}
		case PromptType::SelectUnselect: {
			const auto act = take(p, "select", name);
			if(arg(act, 0) == "finish")
				return answer({pick_action(pr, "finish", act)}, act.text);
			const auto code = to_u32(arg(act, 0));
			for(uint32_t i = 0; i < pr.options.size(); ++i)
				if(pr.options[i].card.code == code)
					return answer({i}, act.text);
			fail("line " + std::to_string(act.line) + ": " + content_.label(code) + " is not among the offered choices");
		}
		case PromptType::Chain: {
			// A chain action is only consumed when it is the next scripted step, so
			// earlier windows where the same card could be activated are passed.
			if(next_is(p, "chain")) {
				const auto act = take(p, "chain", name);
				if(arg(act, 0) == "pass")
					return answer({pick_action(pr, "pass", act)}, act.text);
				const auto idx = pick(pr, "activate", to_u32(arg(act, 0)), {}, act);
				last_choice_ = pr.options[idx].card.code;
				return answer({idx}, act.text);
			}
			if(pr.forced) {
				if(pr.options.size() != 1)
					fail("forced chain with " + std::to_string(pr.options.size()) + " options needs a scripted 'chain' for p" + std::to_string(p));
				return answer({0}, "default: only option of a forced chain");
			}
			for(uint32_t i = 0; i < pr.options.size(); ++i)
				if(pr.options[i].action == "pass")
					return answer({i}, "default: pass (not scripted)");
			fail("chain prompt without a pass option");
		}
		case PromptType::Place: {
			std::vector<uint32_t> picks;
			for(uint32_t i = 0; i < pr.min; ++i)
				picks.push_back(i);
			return answer(picks, "default: first free zone");
		}
		case PromptType::Position: {
			if(next_is(p, "position")) {
				const auto act = take(p, "position", name);
				return answer({pick_action(pr, arg(act, 0), act)}, act.text);
			}
			for(const char* pref : {"fu_atk", "fu_def", "fd_def", "fd_atk"})
				for(uint32_t i = 0; i < pr.options.size(); ++i)
					if(pr.options[i].action == pref)
						return answer({i}, std::string("default: ") + pref);
			fail("position prompt without options");
		}
		case PromptType::Counter: {
			// Each code takes one counter from the first matching card that still has one.
			const auto act = take(p, "counter", name);
			std::vector<uint32_t> left, picks;
			for(const auto& o : pr.options)
				left.push_back(o.param);
			for(const auto& code : act.args) {
				uint32_t i = 0;
				while(i < pr.options.size() && !(pr.options[i].card.code == to_u32(code) && left[i] > 0))
					++i;
				if(i == pr.options.size())
					fail("line " + std::to_string(act.line) + ": no counter left on " + content_.label(to_u32(code)));
				--left[i];
				picks.push_back(i);
			}
			return answer(picks, act.text);
		}
		case PromptType::AnnounceRace:
		case PromptType::AnnounceAttribute:
		case PromptType::AnnounceNumber: {
			const auto act = take(p, "announce", name);
			std::vector<uint32_t> picks;
			for(const auto& a : act.args) {
				const auto value = std::stoull(a, nullptr, 0);
				uint32_t i = 0;
				while(i < pr.options.size() && pr.options[i].desc != value)
					++i;
				if(i == pr.options.size())
					fail("line " + std::to_string(act.line) + ": " + a + " is not among the offered choices");
				picks.push_back(i);
			}
			return answer(picks, act.text);
		}
		case PromptType::AnnounceCard: {
			const auto act = take(p, "announce", name);
			return answer({to_u32(arg(act, 0))}, act.text);
		}
		case PromptType::RockPaperScissors: {
			const auto act = take(p, "rps", name);
			return answer({pick_action(pr, arg(act, 0), act)}, act.text);
		}
		case PromptType::Sort: {
			if(!next_is(p, "sort"))
				return answer({}, "default: core order");
			const auto act = take(p, "sort", name);
			std::vector<uint32_t> picks;
			for(const auto& code : act.args)
				picks.push_back(pick(pr, "card", to_u32(code), picks, act));
			return answer(picks, act.text);
		}
		}
		fail("unhandled prompt type");
	}

	std::vector<uint32_t> answer(std::vector<uint32_t> picks, const std::string& text) {
		std::printf("  > %s\n", text.c_str());
		return picks;
	}

	// ---- scenario helpers

	// Prompts this test layer answers on its own when the scenario does not script them;
	// like expectations, `stop` waits for the next prompt that needs a scripted answer.
	bool answered_by_default(const battle::Prompt& pr) const {
		if(sc_.script_ai[pr.player & 1])
			return true; // answered by the enemy scripts
		using battle::PromptType;
		switch(pr.type) {
		case PromptType::Place: return true;
		case PromptType::Position: return !next_is(pr.player, "position");
		case PromptType::Chain: return !next_is(pr.player, "chain");
		case PromptType::Sort: return !next_is(pr.player, "sort");
		default: return false;
		}
	}

	const Action* next_player_action() const {
		for(const auto& act : sc_.actions)
			if(act.player != -1)
				return &act;
		return nullptr;
	}

	// Peeks past pending expectations: those only run when a scripted action is
	// consumed, never at prompts answered by default.
	bool next_is(uint8_t player, const char* verb) const {
		const auto* act = next_player_action();
		return act && act->player == player && act->verb == verb;
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

	uint32_t pick(const battle::Prompt& pr, const std::string& action, uint32_t code, const std::vector<uint32_t>& used, const Action& act) {
		for(uint32_t i = 0; i < pr.options.size(); ++i)
			if(pr.options[i].action == action && pr.options[i].card.code == code &&
			   std::find(used.begin(), used.end(), i) == used.end())
				return i;
		fail("line " + std::to_string(act.line) + ": " + content_.label(code) + " is not among the offered choices");
	}

	uint32_t pick_action(const battle::Prompt& pr, const std::string& action, const Action& act) {
		for(uint32_t i = 0; i < pr.options.size(); ++i)
			if(pr.options[i].action == action)
				return i;
		fail("line " + std::to_string(act.line) + ": '" + action + "' is not available right now");
	}

	std::string codes(const std::vector<uint32_t>& list) {
		std::string s;
		for(auto code : list)
			s += (s.empty() ? "" : " ") + std::to_string(code);
		return s;
	}

	void run_expectations() {
		while(!sc_.actions.empty() && sc_.actions.front().player == -1) {
			const auto act = sc_.actions.front();
			sc_.actions.pop_front();
			std::string got, want;
			if(act.verb == "lp") {
				got = std::to_string(duel_->lp(to_u32(arg(act, 0)) & 1));
				want = arg(act, 1);
			} else if(act.verb == "count") {
				got = std::to_string(duel_->count(to_u32(arg(act, 0)) & 1, location_arg(arg(act, 1))));
				want = arg(act, 2);
			} else if(act.verb == "cards") {
				std::vector<uint32_t> list;
				for(const auto& c : duel_->cards(to_u32(arg(act, 0)) & 1, location_arg(arg(act, 1))))
					list.push_back(c.code);
				got = codes(list);
				for(size_t i = 2; i < act.args.size(); ++i)
					want += (want.empty() ? "" : " ") + act.args[i];
			} else if(act.verb == "chain") {
				got = codes(last_chain_);
				for(const auto& a : act.args)
					want += (want.empty() ? "" : " ") + a;
			} else if(act.verb == "win") {
				got = duel_->winner() < 0 ? "none" : std::to_string(duel_->winner()) + (act.args.size() > 1 ? " " + std::to_string(duel_->win_reason()) : "");
				for(const auto& a : act.args)
					want += (want.empty() ? "" : " ") + a;
			} else if(act.verb == "ap") {
				got = std::to_string(duel_->ap(to_u32(arg(act, 0)) & 1));
				want = arg(act, 1);
			} else if(act.verb == "hp") {
				// expect hp CODE n [max]: the enemy unit with this code (the latest one that reported HP)
				const auto it = last_hp_.find(to_u32(arg(act, 0)));
				const auto* hp = it == last_hp_.end() ? nullptr : duel_->hp(it->second);
				got = hp ? std::to_string(hp->hp) + (act.args.size() > 2 ? "/" + std::to_string(hp->max) : "") : "none";
				want = arg(act, 1) + (act.args.size() > 2 ? "/" + arg(act, 2) : "");
			} else if(act.verb == "destroyed") {
				// expect destroyed CODE battle|effect: how the card last left a place
				const auto it = last_move_reason_.find(to_u32(arg(act, 0)));
				const uint32_t r = it == last_move_reason_.end() ? 0 : it->second;
				got = !(r & REASON_DESTROY) ? "not destroyed" : (r & REASON_BATTLE) ? "battle" : (r & REASON_EFFECT) ? "effect" : "other";
				for(size_t i = 1; i < act.args.size(); ++i)
					want += (want.empty() ? "" : " ") + act.args[i];
			} else if(act.verb == "blocked" || act.verb == "cost") {
				// About an option of the prompt being answered right now.
				const auto* pr = duel_->prompt();
				if(!pr)
					fail("line " + std::to_string(act.line) + ": no prompt is pending");
				const battle::Option* found = nullptr;
				for(const auto& o : pr->options)
					if(o.action == arg(act, 0) && o.card.code == to_u32(arg(act, 1)))
						found = &o;
				if(!found)
					fail("line " + std::to_string(act.line) + ": the current prompt has no such option");
				got = act.verb == "cost" ? std::to_string(found->cost) : (found->blocked.empty() ? "allowed" : "blocked");
				want = act.verb == "cost" ? arg(act, 2) : "blocked";
			} else if(act.verb == "retry") {
				fail("line " + std::to_string(act.line) + ": expected the core to reject the previous answer, but it was accepted");
			} else {
				fail("line " + std::to_string(act.line) + ": unknown expectation '" + act.verb + "'");
			}
			if(got != want)
				fail("expectation failed at line " + std::to_string(act.line) + " (" + act.text + "): got " + got);
			std::printf("  ok: %s\n", act.text.c_str());
		}
	}

	Scenario sc_;
	battle::Content& content_;
	battle::Duel* duel_ = nullptr;
	uint32_t last_choice_ = 0;
	std::vector<uint32_t> resolved_, last_chain_;
	std::map<uint32_t, uint32_t> last_move_reason_, last_hp_; // by code: reason / card instance
};

} // namespace

int main(int argc, char** argv) {
	std::setvbuf(stdout, nullptr, _IONBF, 0);
	std::string scripts_dir, enemies_dir, scenario;
	std::vector<std::string> dbs;
	for(int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		if(a == "--scripts" && i + 1 < argc)
			scripts_dir = argv[++i];
		else if(a == "--db" && i + 1 < argc)
			dbs.push_back(argv[++i]);
		else if(a == "--enemies" && i + 1 < argc)
			enemies_dir = argv[++i];
		else
			scenario = a;
	}
	if(scripts_dir.empty() || dbs.empty() || scenario.empty()) {
		std::fprintf(stderr, "usage: duel_harness --scripts DIR --db FILE [--db FILE...] [--enemies DIR] SCENARIO\n");
		return 2;
	}
	try {
		const auto [major, minor] = battle::core_version();
		std::printf("== ocgcore API %d.%d\n", major, minor);
		battle::Content content(scripts_dir, dbs, enemies_dir);
		std::printf("== scenario %s\n", scenario.c_str());
		Runner(load_scenario(scenario), content).run();
	} catch(const std::exception& e) {
		std::printf("FAIL: %s\n", e.what());
		return 1;
	}
	std::printf("PASS\n");
	return 0;
}
