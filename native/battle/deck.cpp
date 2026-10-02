#include "deck.h"
#include <fstream>
#include <stdexcept>

namespace battle {

Deck parse_ydk(std::istream& in, const std::string& name) {
	Deck deck;
	std::vector<uint32_t>* section = nullptr;
	std::string line;
	for(int line_no = 1; std::getline(in, line); ++line_no) {
		auto fail = [&](const std::string& msg) { throw std::runtime_error(name + ":" + std::to_string(line_no) + ": " + msg); };
		const auto first = line.find_first_not_of(" \t\r");
		if(first == std::string::npos)
			continue;
		line = line.substr(first, line.find_last_not_of(" \t\r") - first + 1);
		if(line == "#main")
			section = &deck.main;
		else if(line == "#extra")
			section = &deck.extra;
		else if(line == "!side")
			section = &deck.side;
		else if(line[0] == '#')
			continue; // comment, e.g. "#created by ..."
		else if(line[0] == '!')
			fail("unknown section '" + line + "'");
		else if(line.find_first_not_of("0123456789") != std::string::npos || line.size() > 10)
			fail("expected a card code, got '" + line + "'");
		else if(!section)
			fail("card code before #main");
		else {
			const auto code = std::stoull(line);
			if(code == 0 || code > UINT32_MAX)
				fail("card code out of range: " + line);
			section->push_back(static_cast<uint32_t>(code));
		}
	}
	return deck;
}

Deck load_ydk(const std::string& path) {
	std::ifstream in(path);
	if(!in)
		throw std::runtime_error("cannot open deck file " + path);
	return parse_ydk(in, path);
}

} // namespace battle
