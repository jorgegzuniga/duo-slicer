// Unit tests for the G-code template language.
#include "../Engine/src/templ.hpp"
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
using json = nlohmann::json;
static int fails = 0;
static void check(const std::string& name, const std::string& got, const std::string& want) {
    if (got != want) { ++fails; std::cout << "FAIL " << name << "\n  got:  [" << got << "]\n  want: [" << want << "]\n"; }
    else std::cout << "ok   " << name << "\n";
}
int main(int argc, char** argv) {
    json vars = {{"layer_num", 3}, {"next_extruder", 2}, {"previous_extruder", 0}, {"initial_extruder", 0}, {"initial_tool", 0},
                 {"travel_speed", json::array({"500"})}, {"temperature", json::array({"220", "230", "240", "250"})},
                 {"first_layer_temperature", json::array({"215", "225", "235", "245"})}, {"filament_type", json::array({"PLA", "PETG", "PLA", "PVA"})},
                 {"print_sequence", "by layer"}, {"max_layer_z", 3.2}, {"max_print_height", "270"}, {"z_offset", "0"},
                 {"position", json::array({10.0, 20.0, 3.2})}, {"nozzle_diameter", json::array({"0.4"})}, {"curr_bed_type", "Textured PEI Plate"},
                 {"nozzle_volume_type", json::array({"0", "1", "0", "0"})}, {"filament_map", json::array({"1", "2", "3", "4"})}};
    auto lookup = [&](const std::string& k) { return vars.contains(k) ? vars[k] : json(); };
    std::string err;
    check("legacy subst", a1::renderTemplate("M620 S[next_extruder]A T[temperature[next_extruder]]", lookup, 0, &err), "M620 S2A T240");
    check("macro if", a1::renderTemplate("{if curr_bed_type==\"Textured PEI Plate\"}G29.1 Z{-0.02}{else}none{endif}", lookup, 0, &err), "G29.1 Z-0.02");
    check("vector default idx", a1::renderTemplate("{if (filament_type[next_extruder] == \"PLA\") && (nozzle_diameter != 0.2)}yes{endif}", lookup, 0, &err), "yes");
    check("block locals", a1::renderTemplate("{ local a = 2; local b = a * 3; \"v=\" + b }", lookup, 0, &err), "v=6");
    check("if then block", a1::renderTemplate("{ if layer_num == 0 then \"first\" elsif layer_num < 5 then \"early\" else \"late\" endif }", lookup, 0, &err), "early");
    check("not()", a1::renderTemplate("{ if true and not((layer_num < 0) and (next_extruder == initial_tool)) then \"go\" endif }", lookup, 0, &err), "go");
    check("ternary", a1::renderTemplate("{(nozzle_volume_type[filament_map[1]-1] == 1 ? \"high_flow\" : \"standard\")}", lookup, 0, &err), "high_flow");
    check("size()", a1::renderTemplate("{if size(filament_type) > 3}four{endif}", lookup, 0, &err), "four");
    check("indexed assign", a1::renderTemplate("{ position[2] = position[2] + 2.0; \"z=\" + position[2] }", lookup, 0, &err), "z=5.2");
    check("regex", a1::renderTemplate("{if filament_type[1] =~ /PET.*/}petg{endif}", lookup, 0, &err), "petg");
    check("string+number concat", a1::renderTemplate("{\"M109 S\" + temperature[next_extruder] + \" T\" + next_extruder}", lookup, 0, &err), "M109 S240 T2");
    check("numeric string math", a1::renderTemplate("{temperature[1] - 90}", lookup, 0, &err), "140");
    check("unknown [] literal", a1::renderTemplate("; [not_a_var] ok", lookup, 0, &err), "; [not_a_var] ok");
    check("locals persist across blocks", a1::renderTemplate("{ local mz = 7; }G1 Z{mz}", lookup, 0, &err), "G1 Z7");
    if (!err.empty()) { std::cout << "unexpected error: " << err << "\n"; ++fails; }
    err.clear();
    a1::renderTemplate("{ undefined_thing + 1 }", lookup, 0, &err);
    check("unknown var reported", err.substr(0, 25), "unknown variable undefine");
    if (argc > 1) {  // render a real template file
        std::ifstream f(argv[1]); std::stringstream ss; ss << f.rdbuf();
        err.clear();
        std::cout << "----- rendered " << argv[1] << " -----\n" << a1::renderTemplate(ss.str(), lookup, 0, &err) << "\n----- error: " << err << "\n";
    }
    std::cout << (fails ? "FAILED " : "ALL PASSED ") << fails << "\n";
    return fails ? 1 : 0;
}
