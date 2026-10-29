// Placement edits on the demo project: place, arrange, move between plates, new and removed plates, undo,
// and an exported 3MF that opens again with every object on the same plate at the same spot.
//   t_place profiles/bambu-x1c.json Resources/demo.3mf
#include "../Engine/include/a1engine.h"
#include "nlohmann/json.hpp"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

using json = nlohmann::json;

static std::string slurp(const char* p) {
    std::ifstream f(p, std::ios::binary);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

static int failures = 0;
static void check(bool ok, const std::string& what) {
    std::cout << (ok ? "ok   " : "FAIL ") << what << "\n";
    if (!ok) failures++;
}

static json take(char* s) {
    json j = json::parse(s);
    a1_free(s);
    return j;
}

static json info(A1Engine* e) { return take(a1_info(e)); }

struct Box { double x0, y0, x1, y1; };
static Box box(const json& o) { return {o["min"][0], o["min"][1], o["max"][0], o["max"][1]}; }
static double gapBetween(const Box& a, const Box& b) {
    double dx = std::max(b.x0 - a.x1, a.x0 - b.x1), dy = std::max(b.y0 - a.y1, a.y0 - b.y1);
    return std::max(dx, dy);  // > 0: apart by at least this much on one axis
}

static int objectIndex(const json& j, const std::string& name) {
    for (auto& p : j["plates"])
        for (auto& o : p["objects"])
            if (o["name"] == name) return o["index"];
    return -1;
}

static int plateOf(const json& j, const std::string& name) {
    for (auto& p : j["plates"])
        for (auto& o : p["objects"])
            if (o["name"] == name) return p["index"];
    return -1;
}

static json objectNamed(const json& j, const std::string& name) {
    for (auto& p : j["plates"])
        for (auto& o : p["objects"])
            if (o["name"] == name) return o;
    return json();
}

// every object on every plate fits, and objects on a plate are at least `gap` apart
static bool tidy(const json& j, double gap, std::string& why) {
    for (auto& p : j["plates"]) {
        auto& objs = p["objects"];
        for (auto& o : objs)
            if (!o["fit"].get<std::string>().empty()) { why = o["name"].get<std::string>() + " " + o["fit"].get<std::string>(); return false; }
        for (size_t a = 0; a < objs.size(); ++a)
            for (size_t b = a + 1; b < objs.size(); ++b)
                if (gapBetween(box(objs[a]), box(objs[b])) < gap - 0.01) {
                    why = objs[a]["name"].get<std::string>() + " and " + objs[b]["name"].get<std::string>() + " overlap";
                    return false;
                }
    }
    return true;
}

int main(int argc, char** argv) {
    if (argc < 3) { std::cerr << "usage: t_place profile.json project.3mf\n"; return 2; }
    std::string prof = slurp(argv[1]), proj = slurp(argv[2]);
    A1Engine* e = a1_create(prof.c_str());
    json o = take(a1_open(e, (const uint8_t*)proj.data(), proj.size()));
    check(o.value("ok", false), "open");
    json j = o["project"];
    check(j["plates"].size() == 2, "two plates");
    check(j["can_undo"] == false, "nothing to undo yet");
    int tag1 = objectIndex(j, "Tag 1"), tag2 = objectIndex(j, "Tag 2"), tag3 = objectIndex(j, "Tag 3"), coaster = objectIndex(j, "Coaster");
    check(tag1 >= 0 && tag2 >= 0 && tag3 >= 0 && coaster >= 0, "objects found");
    int tagsPlate = plateOf(j, "Tag 1");

    // place
    check(a1_place_object(e, tag1, 100, 120) == 0, "place Tag 1");
    j = info(e);
    Box b = box(objectNamed(j, "Tag 1"));
    check(std::fabs((b.x0 + b.x1) / 2 - 100) < 0.01 && std::fabs((b.y0 + b.y1) / 2 - 120) < 0.01, "Tag 1 centred at 100, 120");
    check(j["can_undo"] == true, "undo available");
    check(objectNamed(j, "Tag 1")["edited"] == true, "Tag 1 shows as moved");

    // move by
    check(a1_move_object(e, tag1, 5, -10) == 0, "move Tag 1 by 5, -10");
    j = info(e);
    Box b2 = box(objectNamed(j, "Tag 1"));
    check(std::fabs(b2.x0 - b.x0 - 5) < 0.01 && std::fabs(b2.y0 - b.y0 + 10) < 0.01, "moved by the offset");

    // arrange
    json ar = take(a1_arrange(e, tagsPlate, "{}"));
    check(ar.value("ok", false) && ar["placed"] == 3 && ar["left_over"].empty(), "arrange places all three tags");
    std::string why;
    check(tidy(ar["project"], 6, why), "arranged plate is tidy " + why);

    // move to the other plate: lands clear of the coaster
    json mv = take(a1_move_to_plate(e, tag2, plateOf(j, "Coaster")));
    check(mv.value("ok", false) && mv["plate"] == plateOf(j, "Coaster"), "Tag 2 to the coaster's plate");
    j = mv["project"];
    check(plateOf(j, "Tag 2") == plateOf(j, "Coaster"), "Tag 2 listed on the coaster plate");
    check(tidy(j, 6, why), "coaster plate is tidy " + why);

    // move to a new plate
    json nw = take(a1_move_to_plate(e, tag3, -1));
    check(nw.value("ok", false) && nw["plate"] == 2, "Tag 3 to a new plate");
    j = nw["project"];
    check(j["plates"].size() == 3 && j["plates"][2]["objects"].size() == 1, "three plates, Tag 3 alone on the new one");
    check(j["plates"][2]["name"] == "Plate 3", "new plate named Plate 3");
    check(tidy(j, 6, why), "all plates tidy " + why);

    // slice the coaster plate with Tag 2 on it
    json sl = take(a1_slice(e, plateOf(j, "Coaster"), "{}", nullptr, nullptr));
    check(sl.value("ok", false), "slice the coaster plate with two objects " + sl.value("error", std::string()));

    // export and open again: same plates, same spots
    uint8_t* d = nullptr;
    size_t n = 0;
    check(a1_export_project(e, &d, &n) == 0, "export");
    std::string bytes((const char*)d, n);
    a1_free(d);
    A1Engine* e2 = a1_create(prof.c_str());
    json o2 = take(a1_open(e2, (const uint8_t*)bytes.data(), bytes.size()));
    check(o2.value("ok", false), "exported project opens");
    json j2 = o2["project"];
    check(j2["plates"].size() == 3, "exported project has three plates");
    for (const char* name : {"Coaster", "Tag 1", "Tag 2", "Tag 3"}) {
        check(plateOf(j2, name) == plateOf(j, name), std::string(name) + " on the same plate after export");
        Box a = box(objectNamed(j, name)), c = box(objectNamed(j2, name));
        check(std::fabs(a.x0 - c.x0) < 0.01 && std::fabs(a.y0 - c.y0) < 0.01, std::string(name) + " at the same spot after export");
    }
    a1_destroy(e2);

    // undo the new plate, then the move to the coaster plate
    check(a1_undo(e) == 0, "undo");
    j = info(e);
    check(j["plates"].size() == 2 && plateOf(j, "Tag 3") == tagsPlate, "undo puts Tag 3 back and removes the new plate");
    check(a1_undo(e) == 0, "undo again");
    j = info(e);
    check(plateOf(j, "Tag 2") == tagsPlate, "Tag 2 back on the tags plate");

    // an empty plate can be removed, a full one can't
    int added = a1_add_plate(e);
    check(added == 2, "add an empty plate");
    check(a1_remove_plate(e, tagsPlate) == -1, "a plate with objects can't be removed");
    check(a1_remove_plate(e, added) == 0, "remove the empty plate");
    j = info(e);
    check(j["plates"].size() == 2, "back to two plates");

    // everything onto the coaster plate, then arrange: whatever doesn't fit is reported
    for (const char* name : {"Tag 1", "Tag 2", "Tag 3"}) take(a1_move_to_plate(e, objectIndex(j, name), plateOf(j, "Coaster")));
    j = info(e);
    check(j["plates"][tagsPlate]["empty"] == true, "tags plate is empty after moving its objects away");
    json ar2 = take(a1_arrange(e, plateOf(j, "Coaster"), "{\"allow_rotation\":true}"));
    check(ar2.value("ok", false) && ar2["placed"] == 4, "arrange fits the coaster and three tags on one plate");
    check(tidy(ar2["project"], 6, why), "combined plate tidy " + why);

    a1_destroy(e);
    std::cout << (failures ? std::to_string(failures) + " failed" : std::string("placement test passed")) << "\n";
    return failures ? 1 : 0;
}
