// Self-checks for the battle module that scenario files cannot express: .ydk
// parsing, the prompt lifecycle (no work while waiting, stale/invalid answers),
// deterministic shuffling, and tearing a duel down and creating it again.
// Run from the repository root.
#include <algorithm>
#include <cstdio>
#include <set>
#include <sstream>
#include <stdexcept>
#include "battle.h"
#include "deck.h"
#include "ocgapi_constants.h"

namespace {

int g_failures = 0;
#define CHECK(cond) do { if(!(cond)) { std::printf("  FAIL line %d: %s\n", __LINE__, #cond); ++g_failures; } } while(0)

bool contains(const std::string& s, const std::string& part) { return s.find(part) != std::string::npos; }

std::string ydk_error(const std::string& text) {
	std::istringstream in(text);
	try {
		battle::parse_ydk(in, "t.ydk");
	} catch(const std::exception& e) {
		return e.what();
	}
	return "";
}

battle::DuelConfig config_for(const battle::Deck& deck, uint64_t seed) {
	battle::DuelConfig cfg;
	cfg.seed[0] = seed;
	for(auto& p : cfg.players) {
		p.main = deck.main;
		p.extra = deck.extra;
	}
	return cfg;
}

const battle::Prompt* run_to_prompt(battle::Duel& duel) {
	for(int i = 0; i < 100000; ++i) {
		const auto status = duel.advance();
		if(status == battle::Status::Awaiting)
			return duel.prompt();
		if(status != battle::Status::Continue) {
			std::printf("  unexpected status, error: %s\n", duel.error().c_str());
			return nullptr;
		}
	}
	return nullptr;
}

std::vector<uint32_t> codes(battle::Duel& duel, uint8_t player, uint32_t location) {
	std::vector<uint32_t> out;
	for(const auto& c : duel.cards(player, location))
		out.push_back(c.code);
	return out;
}

uint32_t option(const battle::Prompt& pr, const std::string& action) {
	for(uint32_t i = 0; i < pr.options.size(); ++i)
		if(pr.options[i].action == action)
			return i;
	return UINT32_MAX;
}

void test_ydk_parsing() {
	std::printf("ydk parsing\n");
	std::istringstream in("#created by test\r\n#main\r\n100\r\n100\r\n\r\n  200  \r\n# comment\r\n#extra\r\n300\r\n!side\r\n400\r\n");
	const auto deck = battle::parse_ydk(in, "t.ydk");
	CHECK((deck.main == std::vector<uint32_t>{100, 100, 200}));
	CHECK((deck.extra == std::vector<uint32_t>{300}));
	CHECK((deck.side == std::vector<uint32_t>{400}));
	CHECK(contains(ydk_error("100\n"), "t.ydk:1: card code before #main"));
	CHECK(contains(ydk_error("#main\nabc\n"), "t.ydk:2: expected a card code, got 'abc'"));
	CHECK(contains(ydk_error("#main\n!sidedeck\n"), "t.ydk:2: unknown section"));
	CHECK(contains(ydk_error("#main\n0\n"), "t.ydk:2: card code out of range"));
	CHECK(contains(ydk_error("#main\n99999999999\n"), "t.ydk:2:"));

	const auto file = battle::load_ydk("tests/decks/test_basic.ydk");
	CHECK(file.main.size() == 40 && file.extra.size() == 2 && file.side.size() == 2);
	CHECK(std::count(file.main.begin(), file.main.end(), 25259669u) == 3); // duplicates kept
	try {
		battle::load_ydk("tests/decks/missing.ydk");
		CHECK(!"missing file should throw");
	} catch(const std::exception& e) {
		CHECK(contains(e.what(), "cannot open deck file tests/decks/missing.ydk"));
	}
}

void test_duel_lifecycle(battle::Content& content) {
	std::printf("duel from .ydk, prompt lifecycle, recreate\n");
	const auto deck = battle::load_ydk("tests/decks/test_basic.ydk");
	std::vector<uint32_t> first_order;
	std::string first_prompt;
	for(int round = 0; round < 2; ++round) {
		battle::Duel duel(content, config_for(deck, 42));
		const auto* pr = run_to_prompt(duel);
		CHECK(pr && pr->type == battle::PromptType::Idle && pr->player == 0);
		if(!pr)
			return;
		duel.take_events();
		for(uint8_t p = 0; p < 2; ++p) {
			CHECK(duel.count(p, LOCATION_HAND) == 5);
			CHECK(duel.count(p, LOCATION_DECK) == 35);
			CHECK(duel.count(p, LOCATION_EXTRA) == 2); // side deck stays out
		}
		auto order = codes(duel, 0, LOCATION_DECK);
		auto all = order;
		for(auto c : codes(duel, 0, LOCATION_HAND))
			all.push_back(c);
		auto sorted_main = deck.main;
		std::sort(all.begin(), all.end());
		std::sort(sorted_main.begin(), sorted_main.end());
		CHECK(all == sorted_main); // every main deck card is in the duel exactly once
		CHECK(order != std::vector<uint32_t>(deck.main.begin(), deck.main.begin() + 35)); // shuffled
		const auto text = battle::describe(content, *pr);
		if(round == 0) {
			first_order = order;
			first_prompt = text;
		} else {
			CHECK(order == first_order); // same seed, fresh duel: same opening
			CHECK(text == first_prompt);
		}

		// Waiting returns to the host without touching the core.
		const auto id = pr->id;
		for(int i = 0; i < 3; ++i)
			CHECK(duel.advance() == battle::Status::Awaiting);
		CHECK(duel.take_events().empty());

		// Invalid answers are rejected and leave the same prompt pending.
		std::string err;
		CHECK(!duel.submit(id + 1, {0}, err) && contains(err, "stale prompt id"));
		CHECK(!duel.submit(id, {9999}, err) && contains(err, "out of range"));
		CHECK(!duel.submit(id, {}, err) && contains(err, "exactly one"));
		CHECK(duel.prompt() && duel.prompt()->id == id);

		const auto end = option(*pr, "end");
		CHECK(end != UINT32_MAX);
		CHECK(duel.submit(id, {end}, err));
		CHECK(!duel.submit(id, {end}, err) && contains(err, "no prompt")); // no double submit
		const auto* next = run_to_prompt(duel);
		CHECK(next && next->id > id && next->player == 1 && next->type == battle::PromptType::Idle);
		CHECK(duel.count(1, LOCATION_HAND) == 6); // p1 drew for turn 2
	}

	battle::Duel other(content, config_for(deck, 43));
	CHECK(run_to_prompt(other));
	CHECK(codes(other, 0, LOCATION_DECK) != first_order); // seed changes the shuffle
}

// Answers the follow-up prompts of a summon (zone, position, optional chains/effects)
// until the next main phase prompt.
const battle::Prompt* until_idle(battle::Duel& duel) {
	for(auto* pr = run_to_prompt(duel); pr; pr = run_to_prompt(duel)) {
		if(pr->type == battle::PromptType::Idle)
			return pr;
		uint32_t pick = 0;
		if(pr->type == battle::PromptType::Chain || pr->type == battle::PromptType::EffectYesNo)
			pick = option(*pr, pr->type == battle::PromptType::Chain ? "pass" : "no");
		std::string err;
		if(pick == UINT32_MAX || !duel.submit(pr->id, {pick}, err)) {
			std::printf("  could not answer %s: %s\n", battle::to_string(pr->type), err.c_str());
			return nullptr;
		}
	}
	return nullptr;
}

void test_instances(battle::Content& content) {
	std::printf("card instances and origins\n");
	const auto deck = battle::load_ydk("tests/decks/test_basic.ydk");
	auto cfg = config_for(deck, 42);
	cfg.placements.push_back({1, LOCATION_GRAVE, 89631139});
	battle::Duel duel(content, cfg);
	const auto* pr = run_to_prompt(duel);
	CHECK(pr && pr->type == battle::PromptType::Idle);
	if(!pr)
		return;

	// Every card has a distinct id that maps back to the config entry it came from.
	std::set<uint32_t> ids;
	for(uint8_t p = 0; p < 2; ++p) {
		std::set<uint32_t> main_indexes;
		for(uint32_t loc : {LOCATION_DECK, LOCATION_HAND, LOCATION_EXTRA, LOCATION_GRAVE}) {
			for(const auto& c : duel.cards(p, loc)) {
				CHECK(c.instance != 0 && ids.insert(c.instance).second);
				const auto* o = duel.origin(c.instance);
				CHECK(o && o->player == p);
				if(!o)
					continue;
				using Source = battle::CardOrigin::Source;
				if(o->source == Source::Main) {
					CHECK(loc == LOCATION_DECK || loc == LOCATION_HAND);
					CHECK(c.code == deck.main[o->index]);
					main_indexes.insert(o->index);
				} else if(o->source == Source::Extra) {
					CHECK(loc == LOCATION_EXTRA && c.code == deck.extra[o->index]);
				} else {
					CHECK(loc == LOCATION_GRAVE && o->index == 0 && c.code == cfg.placements[0].code);
				}
			}
		}
		CHECK(main_indexes.size() == deck.main.size()); // each deck entry is exactly one instance
	}

	// The same instance id follows a card from hand to the field.
	const auto summon = option(*pr, "summon");
	CHECK(summon != UINT32_MAX);
	if(summon == UINT32_MAX)
		return;
	const auto picked = pr->options[summon].card;
	CHECK(picked.instance != 0 && picked.location == LOCATION_HAND);
	std::string err;
	CHECK(duel.submit(pr->id, {summon}, err));
	CHECK(until_idle(duel));
	bool on_field = false;
	for(const auto& c : duel.cards(0, LOCATION_MZONE))
		on_field = on_field || (c.instance == picked.instance && c.code == picked.code);
	CHECK(on_field);
	CHECK(duel.origin(picked.instance) && duel.origin(picked.instance)->source == battle::CardOrigin::Source::Main);
}

void test_bad_config(battle::Content& content) {
	std::printf("config errors\n");
	battle::DuelConfig cfg;
	cfg.players[0].main = {15025844, 1};
	try {
		battle::Duel duel(content, cfg);
		CHECK(!"unknown card should throw");
	} catch(const std::exception& e) {
		CHECK(contains(e.what(), "p0 main deck: unknown card code 1"));
	}
	battle::Duel after(content, config_for(battle::load_ydk("tests/decks/test_basic.ydk"), 42));
	CHECK(run_to_prompt(after)); // a failed creation leaves nothing behind
}

} // namespace

int main() {
	std::setvbuf(stdout, nullptr, _IONBF, 0);
	try {
		test_ydk_parsing();
		battle::Content content("third_party/CardScripts", {"third_party/BabelCDB/cards.cdb"});
		test_duel_lifecycle(content);
		test_instances(content);
		test_bad_config(content);
	} catch(const std::exception& e) {
		std::printf("  FAIL exception: %s\n", e.what());
		++g_failures;
	}
	std::printf(g_failures ? "FAIL: %d check(s) failed\n" : "PASS\n", g_failures);
	return g_failures ? 1 : 0;
}
