// Battle module: owns one ygopro-core duel and turns its binary protocol into
// events and structured prompts. It never decides anything for a player; the
// host (test harness, future Godot GUI) answers prompts by option index.
#pragma once
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

struct sqlite3;

namespace battle {

// ------------------------------------------------------------ static content

struct CardData {
	uint32_t code = 0, alias = 0, type = 0, level = 0, attribute = 0;
	uint32_t lscale = 0, rscale = 0, link_marker = 0;
	uint64_t race = 0;
	int32_t attack = 0, defense = 0;
	std::vector<uint16_t> setcodes; // zero-terminated, as the core expects
	std::string name;
	bool found = false;
};

// Card databases + script index, shared read-only by every duel. Must outlive them.
class Content {
public:
	Content(const std::string& scripts_dir, const std::vector<std::string>& db_paths);
	~Content();
	Content(const Content&) = delete;
	Content& operator=(const Content&) = delete;
	const CardData& card(uint32_t code);           // cached; .found is false for unknown codes
	std::string label(uint32_t code);              // "Name(code)"
	const std::string* script_path(const std::string& name) const;

private:
	std::vector<sqlite3*> dbs_;
	std::map<uint32_t, CardData> cache_;
	std::map<std::string, std::string> scripts_;
};

// ------------------------------------------------------------------- config

struct PlayerConfig {
	uint32_t lp = 8000, start_draw = 5, draw_per_turn = 1;
	std::vector<uint32_t> main, extra; // main is shuffled from the duel seed before the duel starts
};

struct Placement { // exact, unshuffled placement (fixed rule tests)
	uint8_t player = 0;
	uint32_t location = 0; // LOCATION_DECK/HAND/GRAVE/REMOVED/EXTRA
	uint32_t code = 0;
};

struct DuelConfig {
	uint64_t seed[4] = {1, 2, 3, 4};
	uint64_t flags = 0; // 0 = master rule 5
	PlayerConfig players[2];
	std::vector<Placement> placements; // added after each player's shuffled main/extra
};

// ------------------------------------------------------------ events/prompts

struct CardRef {
	uint32_t code = 0;
	uint8_t controller = 0, location = 0;
	uint32_t sequence = 0, position = 0;
	uint32_t instance = 0; // core card id: same card object for the whole duel; 0 = unknown/zone
};

// Where a card instance came from in the DuelConfig (index is before shuffling).
struct CardOrigin {
	enum class Source { Main, Extra, Placement };
	uint8_t player = 0;
	Source source = Source::Main;
	uint32_t index = 0; // into players[player].main / .extra, or into placements
};

enum class EventType {
	NewTurn, NewPhase, Draw, Move, Summon, SpSummon, FlipSummon, Set,
	Chaining, ChainSolving, ChainEnd, ChainNegated, ChainDisabled,
	Damage, Recover, PayLp, Attack, Win
};

struct Event {
	EventType type{};
	uint8_t player = 0;      // NewTurn/Draw/Damage/Recover/PayLp/Win
	uint32_t value = 0;      // phase, amount, chain link, win reason
	uint32_t reason = 0;     // Move
	CardRef card, from, to;  // card: subject; from/to: Move, Attack (to.location==0: direct)
	std::vector<uint32_t> codes; // Draw
};

enum class PromptType {
	Idle, Battle, EffectYesNo, YesNo, Option, Chain,
	SelectCard, SelectTribute, SelectUnselect, SelectSum, Counter, Place, Position, Sort,
	AnnounceRace, AnnounceAttribute, AnnounceNumber, AnnounceCard, RockPaperScissors
};

struct Option {
	std::string action; // idle: summon/spsummon/repos/mset/sset/activate/battle/end/shuffle
	                    // battle: activate/attack/main2/end; chain: activate/pass
	                    // yes/no; option; card; must (SelectSum, not pickable); select/unselect/finish/cancel
	                    // zone; fu_atk/fd_atk/fu_def/fd_def; race; attribute; number; scissors/rock/paper
	CardRef card;       // card, or zone (controller/location/sequence) for Place
	uint64_t desc = 0;  // effect/option description id (tells several effects of one card apart);
	                    // race/attribute bit; announced number
	uint32_t param = 0; // tribute release value; SelectSum value (low 16 bits, alt value in high 16); counters on card
};

struct Prompt {
	uint64_t id = 0;          // pass back to submit(); stale ids are rejected
	PromptType type{};
	uint8_t player = 0;
	std::vector<Option> options;
	uint32_t min = 1, max = 1; // number of picks (multi-pick prompts); SelectSum: card count bounds
	uint32_t value = 0;        // Counter: counters to remove; SelectSum: target sum; AnnounceRace/Attribute: how many
	bool at_least = false;     // SelectSum: total must reach `value` instead of equalling it
	bool cancelable = false;   // multi-pick: an empty pick list cancels
	bool forced = false;       // Chain: passing is not allowed
	bool retry = false;        // the core rejected the previous answer to this prompt
	uint64_t desc = 0;         // YesNo/EffectYesNo question; Counter: counter type
	CardRef card;              // EffectYesNo/Position subject
	std::vector<uint64_t> filter; // AnnounceCard: the core's declarable-card filter program (opcodes)
};

enum class Status { Continue, Awaiting, Ended, Error };

// ---------------------------------------------------------------------- duel

class Duel {
public:
	// Throws std::runtime_error on bad config (unknown card, missing script, core refusal).
	Duel(Content& content, const DuelConfig& config);
	~Duel(); // destroys the core duel; hiding a screen should keep the Duel alive instead
	Duel(const Duel&) = delete;
	Duel& operator=(const Duel&) = delete;

	// Runs the core one step. Returns immediately (no core call) while a prompt is pending.
	Status advance();
	Status status() const { return status_; }
	const Prompt* prompt() const { return status_ == Status::Awaiting ? &prompt_ : nullptr; }
	// Picks are option indices:
	//   single-choice prompts      exactly one index
	//   SelectCard                 min..max distinct indices (empty = cancel when cancelable)
	//   SelectTribute              1..max distinct indices (empty = cancel when cancelable)
	//   SelectSum                  distinct "card" indices (the "must" cards are always included)
	//   Counter                    `value` indices; repeat an index to take several counters from one card
	//   Place                      exactly `min` zones
	//   Sort                       empty = core default order, or every index once, first = top/first
	//   AnnounceRace/Attribute     exactly `value` distinct indices
	//   AnnounceCard               exactly one card code (not an index); must exist in the databases
	// Shape errors are rejected here (returns false with `error`, prompt stays pending).
	// Game-rule checks (sum totals, counters per card, tribute value, declarable card)
	// are left to the core, which re-asks: the next prompt has retry = true.
	bool submit(uint64_t prompt_id, const std::vector<uint32_t>& picks, std::string& error);
	std::vector<Event> take_events();
	const std::string& error() const { return error_; }

	// State queries, valid in any status.
	uint32_t lp(uint8_t player);
	uint32_t count(uint8_t player, uint32_t location);
	std::vector<CardRef> cards(uint8_t player, uint32_t location); // zones include empty slots (code 0)
	const CardOrigin* origin(uint32_t instance) const;              // nullptr for tokens / unknown ids
	int winner() const { return winner_; }                         // -1 until a MSG_WIN
	uint32_t win_reason() const { return win_reason_; }            // 1 = LP, 2 = deck-out

	// Callbacks from the core (public only for the C callback trampolines).
	void on_card_request(uint32_t code, void* out);
	int on_script_request(const char* name);
	void on_log(const char* text, int type);

private:
	void set_error(const std::string& msg);
	bool parse(const uint8_t* data, size_t size);
	bool parse_message(uint8_t type, const uint8_t* data, size_t size);
	void fill_instance(CardRef& ref); // looks the card up at its current location

	Content& content_;
	void* duel_ = nullptr;
	Status status_ = Status::Continue;
	Prompt prompt_;
	std::vector<std::vector<uint8_t>> encoded_; // response bytes per option (single-choice prompts)
	uint64_t next_prompt_id_ = 1;
	bool auto_answered_ = false; // an empty, optional chain window was passed internally
	std::vector<Event> events_;
	std::vector<uint32_t> chain_;
	std::string error_;
	std::set<std::string> missing_scripts_;
	std::map<uint32_t, CardOrigin> origins_;
	int winner_ = -1;
	uint32_t win_reason_ = 0;
};

// ------------------------------------------------------------------ helpers

// Loaded core's API version; throws if its major version differs from the headers built against.
std::pair<int, int> core_version();
const char* to_string(PromptType type); // e.g. "SELECT_IDLECMD"
std::string describe(Content& content, const Event& event);
std::string describe(Content& content, const Prompt& prompt);
std::string where(const CardRef& ref);  // "p0.hand[2]"
uint32_t parse_location(const std::string& name); // "hand" -> LOCATION_HAND; 0 if unknown

} // namespace battle
