// Minimal ZIP reader/writer on top of zlib (enough for 3MF files).
#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace a1 {

class ZipReader {
public:
    explicit ZipReader(std::string data);
    bool has(const std::string& name) const { return entries_.count(name) > 0; }
    std::string read(const std::string& name) const;  // throws on error
    std::vector<std::string> names() const;

private:
    struct Entry { uint32_t offset, csize, usize; uint16_t method; };
    std::string data_;
    std::map<std::string, Entry> entries_;
};

class ZipWriter {
public:
    void add(const std::string& name, const std::string& content, bool compress = true);
    std::string finish();

private:
    struct Entry { std::string name; uint32_t crc, csize, usize, offset; uint16_t method; };
    std::string out_;
    std::vector<Entry> entries_;
};

std::string md5_hex(const std::string& data);  // uppercase hex

}  // namespace a1
