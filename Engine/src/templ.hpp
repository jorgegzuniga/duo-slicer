// Evaluator for Bambu Studio / PrusaSlicer-style G-code templates:
//   [var] [var[idx]] {expr} {if expr} {elsif expr} {else} {endif}
#pragma once
#include <functional>
#include <string>

#include "nlohmann/json.hpp"

namespace a1 {

// Looks up a variable; returns json null when unknown. Arrays are json arrays (often of strings).
using VarLookup = std::function<nlohmann::json(const std::string&)>;

// `defaultIndex` is used for vector variables referenced without an index (the current filament).
std::string renderTemplate(const std::string& tmpl, const VarLookup& vars, int defaultIndex, std::string* error = nullptr);

std::string fmtNum(double v);

}  // namespace a1
