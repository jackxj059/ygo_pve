// .ydk deck files. Parsing only checks the file format; whether the codes exist is
// checked against the card databases when a duel is created, and deck legality
// (counts, banlists, build points) is a separate, not yet defined rule layer.
#pragma once
#include <cstdint>
#include <istream>
#include <string>
#include <vector>

namespace battle {

struct Deck {
	std::vector<uint32_t> main, extra, side; // file order, duplicates kept
};

// Throws std::runtime_error("<name>:<line>: <problem>") on malformed input.
Deck parse_ydk(std::istream& in, const std::string& name);
Deck load_ydk(const std::string& path);

} // namespace battle
