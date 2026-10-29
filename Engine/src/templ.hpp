// Evaluator for PrusaSlicer / OrcaSlicer / Bambu Studio G-code templates.
//   Text with [var] [var[idx]] substitutions,
//   {expr}, macro conditionals {if c}..{elsif c}..{else}..{endif},
//   and statement blocks { local x = 1; if a then "text" + x; endif }.
#pragma once
#include <functional>
#include <map>
#include <string>

#include "nlohmann/json.hpp"

namespace a1 {

// Looks up a variable; returns json null when unknown. Arrays are json arrays (often of strings).
using VarLookup = std::function<nlohmann::json(const std::string&)>;

// `defaultIndex` is used for vector variables referenced without an index (the current filament).
// `globals` (optional) keeps `global` variables between templates of one G-code file.
std::string renderTemplate(const std::string& tmpl, const VarLookup& vars, int defaultIndex, std::string* error = nullptr,
                           std::map<std::string, nlohmann::json>* globals = nullptr);

std::string fmtNum(double v);

}  // namespace a1
