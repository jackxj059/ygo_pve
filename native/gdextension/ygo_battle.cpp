// GDExtension wrapper that exposes the battle module (native/battle) to GDScript.
//   YgoContent  card databases + Lua scripts; share one between duels.
//   YgoDuel     one duel. Prompts, events and cards come out as Dictionaries that
//               mirror battle::Prompt / battle::Event / battle::CardRef.
// Errors are returned as Strings ("" = ok) instead of crossing into Godot as exceptions.
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <exception>
#include <memory>
#include "battle.h"
#include "deck.h"
#include "ocgapi_constants.h"

using namespace godot;

namespace {

String str(const std::string& s) {
	return String::utf8(s.c_str(), static_cast<int64_t>(s.size()));
}

std::string std_str(const String& s) {
	const CharString u = s.utf8();
	return std::string(u.get_data(), static_cast<size_t>(u.length()));
}

PackedInt64Array ints(const std::vector<uint32_t>& values) {
	PackedInt64Array out;
	for(auto v : values)
		out.push_back(v);
	return out;
}

std::vector<uint32_t> codes_from(const Variant& value) {
	std::vector<uint32_t> out;
	const Array list = value; // accepts Array and PackedInt64Array/PackedInt32Array
	for(int64_t i = 0; i < list.size(); ++i)
		out.push_back(static_cast<uint32_t>(static_cast<int64_t>(list[i])));
	return out;
}

Dictionary card_dict(const battle::CardRef& c) {
	Dictionary d;
	d["code"] = static_cast<int64_t>(c.code);
	d["controller"] = c.controller;
	d["location"] = c.location;
	d["sequence"] = static_cast<int64_t>(c.sequence);
	d["position"] = static_cast<int64_t>(c.position);
	d["instance"] = static_cast<int64_t>(c.instance);
	return d;
}

const char* event_name(battle::EventType t) {
	using E = battle::EventType;
	switch(t) {
	case E::NewTurn: return "new_turn";
	case E::NewPhase: return "new_phase";
	case E::Draw: return "draw";
	case E::Move: return "move";
	case E::Summon: return "summon";
	case E::SpSummon: return "spsummon";
	case E::FlipSummon: return "flip_summon";
	case E::Set: return "set";
	case E::Chaining: return "chaining";
	case E::ChainSolving: return "chain_solving";
	case E::ChainEnd: return "chain_end";
	case E::ChainNegated: return "chain_negated";
	case E::ChainDisabled: return "chain_disabled";
	case E::Damage: return "damage";
	case E::Recover: return "recover";
	case E::PayLp: return "pay_lp";
	case E::Attack: return "attack";
	case E::Win: return "win";
	case E::Ap: return "ap";
	}
	return "?";
}

} // namespace

class YgoContent : public RefCounted {
	GDCLASS(YgoContent, RefCounted)

	std::unique_ptr<battle::Content> content_;

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("open", "scripts_dir", "db_paths"), &YgoContent::open);
		ClassDB::bind_method(D_METHOD("is_open"), &YgoContent::is_open);
		ClassDB::bind_method(D_METHOD("card_info", "code"), &YgoContent::card_info);
		ClassDB::bind_method(D_METHOD("description", "desc"), &YgoContent::description);
		ClassDB::bind_static_method("YgoContent", D_METHOD("load_ydk", "path"), &YgoContent::load_ydk);
	}

public:
	battle::Content* get() const { return content_.get(); }

	String open(const String& scripts_dir, const PackedStringArray& db_paths) {
		std::vector<std::string> dbs;
		for(int64_t i = 0; i < db_paths.size(); ++i)
			dbs.push_back(std_str(db_paths[i]));
		try {
			content_ = std::make_unique<battle::Content>(std_str(scripts_dir), dbs);
		} catch(const std::exception& e) {
			content_.reset();
			return str(e.what());
		}
		return "";
	}

	bool is_open() const { return content_ != nullptr; }

	Dictionary card_info(int64_t code) {
		Dictionary d;
		if(!content_)
			return d;
		const auto& cd = content_->card(static_cast<uint32_t>(code));
		d["code"] = static_cast<int64_t>(cd.code);
		d["found"] = cd.found;
		d["name"] = str(cd.name);
		d["text"] = str(cd.text);
		d["alias"] = static_cast<int64_t>(cd.alias);
		d["type"] = static_cast<int64_t>(cd.type);
		d["level"] = static_cast<int64_t>(cd.level);
		d["attribute"] = static_cast<int64_t>(cd.attribute);
		d["race"] = static_cast<int64_t>(cd.race);
		d["attack"] = cd.attack;
		d["defense"] = cd.defense;
		d["lscale"] = static_cast<int64_t>(cd.lscale);
		d["rscale"] = static_cast<int64_t>(cd.rscale);
		d["link_marker"] = static_cast<int64_t>(cd.link_marker);
		return d;
	}

	String description(int64_t desc) {
		return content_ ? str(content_->description(static_cast<uint64_t>(desc))) : String();
	}

	static Dictionary load_ydk(const String& path) {
		Dictionary d;
		try {
			const auto deck = battle::load_ydk(std_str(path));
			d["main"] = ints(deck.main);
			d["extra"] = ints(deck.extra);
			d["side"] = ints(deck.side);
			d["error"] = "";
		} catch(const std::exception& e) {
			d["error"] = str(e.what());
		}
		return d;
	}
};

class YgoDuel : public RefCounted {
	GDCLASS(YgoDuel, RefCounted)

	Ref<YgoContent> content_; // keeps the content alive as long as the duel
	std::unique_ptr<battle::Duel> duel_;
	String start_error_;

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("start", "content", "config"), &YgoDuel::start);
		ClassDB::bind_method(D_METHOD("advance"), &YgoDuel::advance);
		ClassDB::bind_method(D_METHOD("status"), &YgoDuel::status);
		ClassDB::bind_method(D_METHOD("take_events"), &YgoDuel::take_events);
		ClassDB::bind_method(D_METHOD("get_prompt"), &YgoDuel::get_prompt);
		ClassDB::bind_method(D_METHOD("submit", "prompt_id", "picks"), &YgoDuel::submit);
		ClassDB::bind_method(D_METHOD("lp", "player"), &YgoDuel::lp);
		ClassDB::bind_method(D_METHOD("count", "player", "location"), &YgoDuel::count);
		ClassDB::bind_method(D_METHOD("cards", "player", "location"), &YgoDuel::cards);
		ClassDB::bind_method(D_METHOD("origin", "instance"), &YgoDuel::origin);
		ClassDB::bind_method(D_METHOD("ap", "player"), &YgoDuel::ap);
		ClassDB::bind_method(D_METHOD("get_error"), &YgoDuel::get_error);
		ClassDB::bind_method(D_METHOD("winner"), &YgoDuel::winner);
		ClassDB::bind_method(D_METHOD("win_reason"), &YgoDuel::win_reason);
		const StringName cls = get_class_static();
		const std::pair<const char*, int64_t> constants[] = {
			{"STATUS_CONTINUE", static_cast<int64_t>(battle::Status::Continue)},
			{"STATUS_AWAITING", static_cast<int64_t>(battle::Status::Awaiting)},
			{"STATUS_ENDED", static_cast<int64_t>(battle::Status::Ended)},
			{"STATUS_ERROR", static_cast<int64_t>(battle::Status::Error)},
			{"LOCATION_DECK", LOCATION_DECK}, {"LOCATION_HAND", LOCATION_HAND},
			{"LOCATION_MZONE", LOCATION_MZONE}, {"LOCATION_SZONE", LOCATION_SZONE},
			{"LOCATION_GRAVE", LOCATION_GRAVE}, {"LOCATION_REMOVED", LOCATION_REMOVED},
			{"LOCATION_EXTRA", LOCATION_EXTRA}, {"LOCATION_OVERLAY", LOCATION_OVERLAY},
			{"POS_FACEUP_ATTACK", POS_FACEUP_ATTACK}, {"POS_FACEDOWN_ATTACK", POS_FACEDOWN_ATTACK},
			{"POS_FACEUP_DEFENSE", POS_FACEUP_DEFENSE}, {"POS_FACEDOWN_DEFENSE", POS_FACEDOWN_DEFENSE},
			{"TYPE_MONSTER", TYPE_MONSTER}, {"TYPE_SPELL", TYPE_SPELL}, {"TYPE_TRAP", TYPE_TRAP},
			{"TYPE_LINK", TYPE_LINK}, {"TYPE_XYZ", TYPE_XYZ},
		};
		for(const auto& [name, value] : constants)
			ClassDB::bind_integer_constant(cls, "", name, value);
	}

public:
	// config: {seed: [a,b,c,d] or int, flags: int,
	//          players: [{lp, start_draw, draw_per_turn, main: [codes], extra: [codes],
	//                     ap: {max, initial, costs: {kind: n}} (optional)}, {...}],
	//          placements: [{player, location, code}, ...]}
	String start(const Ref<YgoContent>& content, const Dictionary& config) {
		duel_.reset();
		if(content.is_null() || !content->get())
			return start_error_ = "content is not open";
		content_ = content;
		battle::DuelConfig cfg;
		const Variant seed = config.get("seed", Variant());
		if(seed.get_type() == Variant::INT) {
			cfg.seed[0] = static_cast<uint64_t>(static_cast<int64_t>(seed));
		} else if(seed.get_type() != Variant::NIL) {
			const Array parts = seed;
			for(int64_t i = 0; i < parts.size() && i < 4; ++i)
				cfg.seed[i] = static_cast<uint64_t>(static_cast<int64_t>(parts[i]));
		}
		cfg.flags = static_cast<uint64_t>(static_cast<int64_t>(config.get("flags", 0)));
		const Array players = config.get("players", Array());
		for(int64_t i = 0; i < players.size() && i < 2; ++i) {
			const Dictionary p = players[i];
			auto& out = cfg.players[i];
			out.lp = static_cast<uint32_t>(static_cast<int64_t>(p.get("lp", out.lp)));
			out.start_draw = static_cast<uint32_t>(static_cast<int64_t>(p.get("start_draw", out.start_draw)));
			out.draw_per_turn = static_cast<uint32_t>(static_cast<int64_t>(p.get("draw_per_turn", out.draw_per_turn)));
			out.main = codes_from(p.get("main", Array()));
			out.extra = codes_from(p.get("extra", Array()));
			// ap: {max, initial, costs: {summon, spsummon, set, activate, attack, repos}}; absent = no AP
			const Variant ap = p.get("ap", Variant());
			if(ap.get_type() == Variant::DICTIONARY) {
				const Dictionary apd = ap;
				out.ap.enabled = true;
				out.ap.max = static_cast<uint32_t>(static_cast<int64_t>(apd.get("max", 0)));
				out.ap.initial = static_cast<uint32_t>(static_cast<int64_t>(apd.get("initial", out.ap.max)));
				const Dictionary costs = apd.get("costs", Dictionary());
				const Array kinds = costs.keys();
				for(int64_t k = 0; k < kinds.size(); ++k)
					out.ap.costs[std_str(kinds[k])] = static_cast<uint32_t>(static_cast<int64_t>(costs[kinds[k]]));
			}
		}
		const Array placements = config.get("placements", Array());
		for(int64_t i = 0; i < placements.size(); ++i) {
			const Dictionary pl = placements[i];
			cfg.placements.push_back({static_cast<uint8_t>(static_cast<int64_t>(pl.get("player", 0)) & 1),
			                          static_cast<uint32_t>(static_cast<int64_t>(pl.get("location", 0))),
			                          static_cast<uint32_t>(static_cast<int64_t>(pl.get("code", 0)))});
		}
		try {
			duel_ = std::make_unique<battle::Duel>(*content_->get(), cfg);
		} catch(const std::exception& e) {
			return start_error_ = str(e.what());
		}
		return start_error_ = "";
	}

	int64_t advance() { return duel_ ? static_cast<int64_t>(duel_->advance()) : static_cast<int64_t>(battle::Status::Error); }
	int64_t status() const { return duel_ ? static_cast<int64_t>(duel_->status()) : static_cast<int64_t>(battle::Status::Error); }

	Array take_events() {
		Array out;
		if(!duel_)
			return out;
		for(const auto& e : duel_->take_events()) {
			Dictionary d;
			d["type"] = event_name(e.type);
			d["text"] = str(battle::describe(*content_->get(), e));
			d["player"] = e.player;
			d["value"] = static_cast<int64_t>(e.value);
			d["reason"] = static_cast<int64_t>(e.reason);
			d["card"] = card_dict(e.card);
			d["from"] = card_dict(e.from);
			d["to"] = card_dict(e.to);
			d["codes"] = ints(e.codes);
			out.push_back(d);
		}
		return out;
	}

	Dictionary get_prompt() {
		Dictionary d;
		const auto* p = duel_ ? duel_->prompt() : nullptr;
		if(!p)
			return d;
		d["id"] = static_cast<int64_t>(p->id);
		d["type"] = battle::to_string(p->type);
		d["player"] = p->player;
		d["min"] = static_cast<int64_t>(p->min);
		d["max"] = static_cast<int64_t>(p->max);
		d["value"] = static_cast<int64_t>(p->value);
		d["at_least"] = p->at_least;
		d["cancelable"] = p->cancelable;
		d["forced"] = p->forced;
		d["retry"] = p->retry;
		d["desc"] = static_cast<int64_t>(p->desc);
		d["card"] = card_dict(p->card);
		PackedInt64Array filter;
		for(auto op : p->filter)
			filter.push_back(static_cast<int64_t>(op));
		d["filter"] = filter;
		Array options;
		for(const auto& o : p->options) {
			Dictionary od;
			od["action"] = str(o.action);
			od["card"] = card_dict(o.card);
			od["desc"] = static_cast<int64_t>(o.desc);
			od["param"] = static_cast<int64_t>(o.param);
			od["cost"] = static_cast<int64_t>(o.cost);
			od["blocked"] = str(o.blocked);
			options.push_back(od);
		}
		d["options"] = options;
		d["text"] = str(battle::describe(*content_->get(), *p));
		return d;
	}

	String submit(int64_t prompt_id, const PackedInt64Array& picks) {
		if(!duel_)
			return "no duel";
		std::vector<uint32_t> values;
		for(int64_t i = 0; i < picks.size(); ++i)
			values.push_back(static_cast<uint32_t>(picks[i]));
		std::string error;
		return duel_->submit(static_cast<uint64_t>(prompt_id), values, error) ? String() : str(error);
	}

	int64_t lp(int64_t player) { return duel_ ? duel_->lp(static_cast<uint8_t>(player)) : 0; }
	int64_t count(int64_t player, int64_t location) {
		return duel_ ? duel_->count(static_cast<uint8_t>(player), static_cast<uint32_t>(location)) : 0;
	}

	Array cards(int64_t player, int64_t location) {
		Array out;
		if(duel_)
			for(const auto& c : duel_->cards(static_cast<uint8_t>(player), static_cast<uint32_t>(location)))
				out.push_back(card_dict(c));
		return out;
	}

	Dictionary ap(int64_t player) {
		Dictionary d;
		const auto p = static_cast<uint8_t>(player);
		d["enabled"] = duel_ ? duel_->ap_enabled(p) : false;
		d["current"] = duel_ ? static_cast<int64_t>(duel_->ap(p)) : 0;
		d["max"] = duel_ ? static_cast<int64_t>(duel_->ap_max(p)) : 0;
		return d;
	}

	Dictionary origin(int64_t instance) {
		Dictionary d;
		const auto* o = duel_ ? duel_->origin(static_cast<uint32_t>(instance)) : nullptr;
		if(!o)
			return d;
		using Source = battle::CardOrigin::Source;
		d["player"] = o->player;
		d["source"] = o->source == Source::Main ? "main" : o->source == Source::Extra ? "extra" : "placement";
		d["index"] = static_cast<int64_t>(o->index);
		return d;
	}

	String get_error() const { return duel_ ? str(duel_->error()) : start_error_; }
	int64_t winner() const { return duel_ ? duel_->winner() : -1; }
	int64_t win_reason() const { return duel_ ? duel_->win_reason() : 0; }
};

namespace {

void initialize_ygo_battle(ModuleInitializationLevel level) {
	if(level != MODULE_INITIALIZATION_LEVEL_SCENE)
		return;
	GDREGISTER_CLASS(YgoContent);
	GDREGISTER_CLASS(YgoDuel);
}

void uninitialize_ygo_battle(ModuleInitializationLevel) {}

} // namespace

extern "C" GDExtensionBool GDE_EXPORT ygo_battle_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                                              GDExtensionClassLibraryPtr library,
                                                              GDExtensionInitialization* initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize_ygo_battle);
	init.register_terminator(uninitialize_ygo_battle);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
