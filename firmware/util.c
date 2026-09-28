//
// String / number helpers (no libc beyond picorv32.c).
//

#include "common.h"

uint8_t to_bcd(uint32_t v) {
    return (uint8_t)(((v / 10) << 4) | (v % 10));
}

int from_bcd(uint8_t value) {
    if ((value & 0x0f) > 9 || (value >> 4) > 9)
        return -1;
    return (value >> 4) * 10 + (value & 0x0f);
}

// Extrait le nom du fichier sans le chemin
void extract_filename(char *dst, const char *path) {
    const char *slash = strrchr(path, '/');
    const char *src = slash ? (slash + 1) : path;
    strncpy(dst, src, NAME_MAX - 1);
    dst[NAME_MAX - 1] = '\0';
}

int build_game_path(char *dst, size_t max_len, const char *directory,
                    const char *game_name, const char *suffix,
                    int strip_extension) {
    size_t directory_len;
    size_t game_len;
    size_t suffix_len;
    const char *extension;

    if (max_len == 0)
        return -1;
    dst[0] = '\0';
    if (!directory || !game_name || !suffix)
        return -1;

    directory_len = strlen(directory);
    game_len = strlen(game_name);
    suffix_len = strlen(suffix);
    extension = strrchr(game_name, '.');
    if (strip_extension && extension && extension != game_name)
        game_len = (size_t)(extension - game_name);

    if (directory_len >= max_len ||
        game_len > max_len - directory_len - 1 ||
        suffix_len > max_len - directory_len - game_len - 1)
        return -1;

    memcpy(dst, directory, directory_len);
    memcpy(dst + directory_len, game_name, game_len);
    memcpy(dst + directory_len + game_len, suffix, suffix_len);
    dst[directory_len + game_len + suffix_len] = '\0';
    return 0;
}

// Conversion d'un entier 8-bit en chaîne de caractères texte
int u8_to_str(char *buf, uint8_t val) {
    if (val >= 100) {
        buf[0] = '0' + (val / 100);
        buf[1] = '0' + ((val / 10) % 10);
        buf[2] = '0' + (val % 10);
        buf[3] = '\0';
        return 3;
    } else if (val >= 10) {
        buf[0] = '0' + (val / 10);
        buf[1] = '0' + (val % 10);
        buf[2] = '\0';
        return 2;
    } else {
        buf[0] = '0' + val;
        buf[1] = '\0';
        return 1;
    }
}

// Comparaison de chaînes sans string.h
int starts_with(const char *line, const char *prefix) {
    while (*prefix) {
        if (*line++ != *prefix++) return 0;
    }
    return 1;
}

int starts_with_ci_n(const char *line, const char *prefix, int n) {
    for (int i = 0; i < n; i++) {
        char a = line[i];
        char b = prefix[i];
        if (a >= 'a' && a <= 'z') a -= 'a' - 'A';
        if (b >= 'a' && b <= 'z') b -= 'a' - 'A';
        if (a != b) return 0;
    }
    return 1;
}

// Extraction de la valeur numérique
uint8_t parse_u8(const char *str) {
    uint8_t val = 0;
    while (*str >= '0' && *str <= '9') {
        val = val * 10 + (*str - '0');
        str++;
    }
    return val;
}

int contains_ci(const char *line, const char *needle) {
    while (*line) {
        if (starts_with_ci_n(line, needle, (int)strlen(needle)))
            return 1;
        line++;
    }
    return 0;
}
