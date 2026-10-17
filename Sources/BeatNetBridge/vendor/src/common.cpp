#include "common.h"

#include <cmath>
#include <cstdio>
#include <cstring>

// ---------------------------------------------------------------------------
// npy
// ---------------------------------------------------------------------------

bool npy_load(const std::string & path, npy_array & out) {
    FILE * f = fopen(path.c_str(), "rb");
    if (!f) {
        fprintf(stderr, "npy_load: cannot open %s\n", path.c_str());
        return false;
    }
    unsigned char magic[8];
    if (fread(magic, 1, 8, f) != 8 || memcmp(magic, "\x93NUMPY", 6) != 0) {
        fprintf(stderr, "npy_load: bad magic in %s\n", path.c_str());
        fclose(f);
        return false;
    }
    int major = magic[6];
    uint32_t hlen = 0;
    if (major == 1) {
        uint16_t h16;
        fread(&h16, 2, 1, f);
        hlen = h16;
    } else {
        fread(&hlen, 4, 1, f);
    }
    std::string header(hlen, '\0');
    fread(&header[0], 1, hlen, f);

    if (header.find("'<f4'") == std::string::npos && header.find("'|f4'") == std::string::npos) {
        fprintf(stderr, "npy_load: only <f4 supported (%s)\n", path.c_str());
        fclose(f);
        return false;
    }
    if (header.find("'fortran_order': False") == std::string::npos) {
        fprintf(stderr, "npy_load: only C-order supported (%s)\n", path.c_str());
        fclose(f);
        return false;
    }
    size_t p = header.find("'shape': (");
    p += strlen("'shape': (");
    size_t e = header.find(")", p);
    std::string shape_str = header.substr(p, e - p);

    out.shape.clear();
    const char * s = shape_str.c_str();
    while (*s) {
        while (*s == ' ' || *s == ',') s++;
        if (!*s) break;
        out.shape.push_back(strtoll(s, (char **) &s, 10));
    }
    if (out.shape.empty()) out.shape.push_back(1);

    out.data.resize(out.n_elements());
    size_t got = fread(out.data.data(), sizeof(float), out.data.size(), f);
    fclose(f);
    if (got != out.data.size()) {
        fprintf(stderr, "npy_load: short read in %s\n", path.c_str());
        return false;
    }
    return true;
}

bool npy_save(const std::string & path, const float * data, const std::vector<int64_t> & shape) {
    FILE * f = fopen(path.c_str(), "wb");
    if (!f) return false;
    std::string shp;
    for (size_t i = 0; i < shape.size(); i++) {
        shp += std::to_string(shape[i]);
        if (shape.size() == 1 || i + 1 < shape.size()) shp += ",";
        if (i + 1 < shape.size()) shp += " ";
    }
    char hdr[512];
    snprintf(hdr, sizeof(hdr), "{'descr': '<f4', 'fortran_order': False, 'shape': (%s), }", shp.c_str());
    size_t hl = strlen(hdr);
    size_t total = 10 + hl;
    size_t pad = (64 - (total % 64)) % 64;
    std::string header(hdr);
    header += std::string(pad, ' ');
    header.back() = '\n';
    uint16_t hlen = (uint16_t) header.size();
    fwrite("\x93NUMPY\x01\x00", 1, 8, f);
    fwrite(&hlen, 2, 1, f);
    fwrite(header.data(), 1, header.size(), f);
    int64_t n = 1;
    for (auto s : shape) n *= s;
    fwrite(data, sizeof(float), n, f);
    fclose(f);
    return true;
}

float max_abs_diff(const float * a, const float * b, int64_t n) {
    float m = 0.f;
    for (int64_t i = 0; i < n; i++) {
        if (std::isinf(a[i]) && std::isinf(b[i]) && ((a[i] > 0) == (b[i] > 0))) continue;
        float d = fabsf(a[i] - b[i]);
        if (d > m) m = d;
    }
    return m;
}
