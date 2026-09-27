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

// Construit le chemin /config/[game_name].cfg sans snprintf
void build_cfg_path(char *dst, size_t max_len, const char *game_name) {
    const char *dir = "/config/";
    const char *ext = ".cfg";
    size_t i = 0;

    // Copie "/config/"
    while (*dir && i < max_len - 1) {
        dst[i++] = *dir++;
    }
    // Copie le nom du jeu
    while (*game_name && i < max_len - 1) {
        dst[i++] = *game_name++;
    }
    // Copie ".cfg"
    while (*ext && i < max_len - 1) {
        dst[i++] = *ext++;
    }
    dst[i] = '\0';
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
