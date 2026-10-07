#include "common.h"
#include "cheats.h"
#include "settings.h"

#define CHEAT_GROUP_MAX 64
#define CHEAT_PATCH_MAX 32
#define CHEAT_CD_PATCH_MAX 8
#define CHEAT_DESC_SIZE 96

typedef struct {
    uint32_t address;
    uint8_t value;
} cheat_patch_t;

typedef struct {
    char description[CHEAT_DESC_SIZE];
    cheat_patch_t patches[CHEAT_PATCH_MAX];
    uint8_t patch_count;
    uint8_t fields;
    uint8_t enabled;
} cheat_group_t;

static cheat_group_t groups[CHEAT_GROUP_MAX];
static int group_count;
static int enabled_groups;
static char status_text[32] = "No cheats file";

static int hardware_patch_limit(void) {
    return CORE_PROFILE_ID == CORE_PROFILE_CD ? CHEAT_CD_PATCH_MAX
                                               : CHEAT_PATCH_MAX;
}

static char *trim(char *text) {
    char *end;
    while (*text == ' ' || *text == '\t')
        text++;
    end = text + strlen(text);
    while (end > text && (end[-1] == ' ' || end[-1] == '\t' ||
                           end[-1] == '\r' || end[-1] == '\n'))
        *--end = '\0';
    return text;
}

static int parse_decimal(const char *text, unsigned *value) {
    unsigned result = 0;
    if (!*text)
        return -1;
    while (*text) {
        if (*text < '0' || *text > '9' || result > 1000)
            return -1;
        result = result * 10 + (unsigned)(*text++ - '0');
    }
    *value = result;
    return 0;
}

static int parse_hex(const char *text, uint32_t limit, uint32_t *value) {
    uint32_t result = 0;
    int digits = 0;
    while (*text) {
        unsigned digit;
        if (*text >= '0' && *text <= '9')
            digit = (unsigned)(*text - '0');
        else if (*text >= 'a' && *text <= 'f')
            digit = (unsigned)(*text - 'a' + 10);
        else if (*text >= 'A' && *text <= 'F')
            digit = (unsigned)(*text - 'A' + 10);
        else
            return -1;
        if (digit > limit || result > (limit - digit) / 16)
            return -1;
        result = result * 16 + digit;
        digits++;
        text++;
    }
    if (!digits)
        return -1;
    *value = result;
    return 0;
}

static int parse_code(char *text, cheat_group_t *group) {
    char *part = text;
    group->patch_count = 0;
    for (;;) {
        char *plus = strchr(part, '+');
        char *colon;
        char *address_text;
        char *value_text;
        uint32_t address, value;
        if (plus)
            *plus = '\0';
        part = trim(part);
        colon = strchr(part, ':');
        if (!colon || strchr(colon + 1, ':') ||
            group->patch_count == CHEAT_PATCH_MAX)
            return -1;
        *colon = '\0';
        address_text = trim(part);
        value_text = trim(colon + 1);
        if (parse_hex(address_text, 0x1fffff, &address) != 0 ||
            parse_hex(value_text, 0xff, &value) != 0)
            return -1;
        group->patches[group->patch_count].address = address;
        group->patches[group->patch_count].value = (uint8_t)value;
        group->patch_count++;
        if (!plus)
            return 0;
        part = plus + 1;
    }
}

static int parse_indexed_key(char *key, unsigned *index, char **field) {
    unsigned value = 0;
    char *cursor;
    if (!starts_with(key, "cheat"))
        return 0;
    cursor = key + 5;
    if (*cursor < '0' || *cursor > '9')
        return -1;
    while (*cursor >= '0' && *cursor <= '9') {
        if (value > 1000)
            return -1;
        value = value * 10 + (unsigned)(*cursor++ - '0');
    }
    if (*cursor++ != '_')
        return -1;
    *index = value;
    *field = cursor;
    return 1;
}

static int parse_cht(FIL *file) {
    char line[512];
    unsigned declared = 0;
    int saw_count = 0;
    memset(groups, 0, sizeof(groups));

    while (f_gets(line, sizeof(line), file)) {
        char *entry = trim(line);
        char *equals;
        char *key, *value;
        unsigned index;
        char *field;
        int indexed;
        if (!*entry || *entry == '#')
            continue;
        equals = strchr(entry, '=');
        if (!equals)
            continue;
        *equals = '\0';
        key = trim(entry);
        value = trim(equals + 1);
        if (strcmp(key, "cheats") == 0) {
            if (saw_count || parse_decimal(value, &declared) != 0 ||
                declared > CHEAT_GROUP_MAX)
                return -1;
            saw_count = 1;
            continue;
        }
        indexed = parse_indexed_key(key, &index, &field);
        if (indexed < 0)
            continue;
        if (!indexed)
            continue;
        if (index >= CHEAT_GROUP_MAX) {
            uart_printf("cheats: ignoring out-of-range index %d\n", (int)index);
            continue;
        }
        cheat_group_t *group = &groups[index];
        if (strcmp(field, "desc") == 0) {
            size_t length = strlen(value);
            if (length < 2 || value[0] != '"' || value[length - 1] != '"' ||
                length - 2 >= sizeof(group->description))
                return -1;
            value[length - 1] = '\0';
            strcpy(group->description, value + 1);
            group->fields |= 1;
        } else if (strcmp(field, "code") == 0) {
            size_t length = strlen(value);
            if (length < 2 || value[0] != '"' || value[length - 1] != '"')
                return -1;
            value[length - 1] = '\0';
            if (parse_code(value + 1, group) != 0)
                return -1;
            group->fields |= 2;
        } else if (strcmp(field, "enable") == 0) {
            if (strcasecmp(value, "true") == 0)
                group->enabled = 1;
            else if (strcasecmp(value, "false") == 0)
                group->enabled = 0;
            else
                return -1;
            group->fields |= 4;
        }
    }
    if (!saw_count)
        return -1;
    for (unsigned i = 0; i < declared; i++) {
        if (groups[i].fields != 7 || groups[i].patch_count == 0) {
            uart_printf("cheats: incomplete group %d\n", (int)i);
            return -1;
        }
    }
    for (unsigned i = declared; i < CHEAT_GROUP_MAX; i++) {
        if (groups[i].fields)
            uart_printf("cheats: ignoring out-of-range index %d\n", (int)i);
    }
    group_count = (int)declared;
    return 0;
}

static int active_patch_count(void) {
    int patches = 0;
    for (int i = 0; i < group_count; i++)
        if (groups[i].enabled)
            patches += groups[i].patch_count;
    return patches;
}

static int hardware_reload(void) {
    if (active_patch_count() > hardware_patch_limit())
        return -1;
    reg_cheat_ctrl = 2;
    for (int i = 0; i < group_count; i++) {
        if (!groups[i].enabled)
            continue;
        for (int p = 0; p < groups[i].patch_count; p++) {
            reg_cheat_addr = groups[i].patches[p].address;
            reg_cheat_value = groups[i].patches[p].value;
            reg_cheat_push = 1;
            reg_cheat_push = 0;
        }
    }
    reg_cheat_ctrl = active_patch_count() ? 1 : 0;
    return 0;
}

void cheats_clear(void) {
    reg_cheat_ctrl = 2;
    group_count = 0;
    enabled_groups = 0;
    strcpy(status_text, "No cheats file");
}

void cheats_load(const char *game_name, enum cheat_game_type type) {
    static const char *directories[] = {
        "/cheats/pce/", "/cheats/sgx/", "/cheats/cd/"
    };
    char path[PWD_SIZE + NAME_MAX + 32];
    uint8_t activated[CHEAT_GROUP_MAX];
    int activated_count = 0;
    int saved_state;
    FIL file;

    cheats_clear();
    if (!game_name || !*game_name || type < CHEAT_GAME_PCE || type > CHEAT_GAME_CD)
        return;
    if (type == CHEAT_GAME_CD && !cheat_cd_enabled)
        return;
    if (build_game_path(path, sizeof(path), directories[type], game_name,
                        ".cht", 1) != 0) {
        strcpy(status_text, "Cheat path too long");
        return;
    }
    FRESULT open_result = f_open(&file, path, FA_READ);
    if (open_result != FR_OK) {
        if (open_result != FR_NO_FILE && open_result != FR_NO_PATH) {
            strcpy(status_text, "Cannot read cheats file");
            uart_printf("cheats: open failed (%d): %s\n", (int)open_result, path);
            return;
        }
        uart_printf("cheats: no file %s\n", path);
        return;
    }
    if (parse_cht(&file) != 0) {
        f_close(&file);
        group_count = 0;
        strcpy(status_text, "Invalid cheats file");
        uart_printf("cheats: invalid file %s\n", path);
        return;
    }
    f_close(&file);

    saved_state = game_cheats_activated_load(game_name, activated,
                                              CHEAT_GROUP_MAX, &activated_count);
    if (saved_state == 1) {
        for (int i = 0; i < group_count; i++)
            groups[i].enabled = 0;
        for (int i = 0; i < activated_count; i++) {
            if (activated[i] < group_count)
                groups[activated[i]].enabled = 1;
            else
                uart_printf("config: ignoring cheat index %d (only %d groups)\n",
                            activated[i], group_count);
        }
    } else if (saved_state < 0) {
        uart_print("cheats: malformed config list; using .cht defaults\n");
    }

    enabled_groups = 0;
    for (int i = 0; i < group_count; i++)
        enabled_groups += groups[i].enabled != 0;
    if (active_patch_count() > hardware_patch_limit()) {
        strcpy(status_text, "Too many active patches");
        for (int i = 0; i < group_count; i++)
            groups[i].enabled = 0;
        enabled_groups = 0;
        uart_print("cheats: active selection exceeds hardware limit\n");
        return;
    }
    if (active_patch_count() != 0 && hardware_reload() != 0) {
        strcpy(status_text, "Too many active patches");
        group_count = 0;
        enabled_groups = 0;
        return;
    }
    status_text[0] = '\0';
}

int cheats_count(void) { return group_count; }
int cheats_active_count(void) { return enabled_groups; }
int cheats_is_active(int index) {
    return index >= 0 && index < group_count && groups[index].enabled;
}
const char *cheats_description(int index) {
    return index >= 0 && index < group_count ? groups[index].description : "";
}
const char *cheats_status(void) { return status_text; }

int cheats_toggle(int index) {
    uint8_t activated[CHEAT_GROUP_MAX];
    int count = 0;
    if (index < 0 || index >= group_count)
        return -1;
    groups[index].enabled = !groups[index].enabled;
    enabled_groups += groups[index].enabled ? 1 : -1;
    if (active_patch_count() > hardware_patch_limit()) {
        groups[index].enabled = !groups[index].enabled;
        enabled_groups += groups[index].enabled ? 1 : -1;
        strcpy(status_text, "Too many active patches");
        return -1;
    }
    if (hardware_reload() != 0) {
        groups[index].enabled = !groups[index].enabled;
        enabled_groups += groups[index].enabled ? 1 : -1;
        return -1;
    }
    for (int i = 0; i < group_count; i++)
        if (groups[i].enabled)
            activated[count++] = (uint8_t)i;
    if (game_cheats_activated_save(current_game_name, activated, count) != 0)
        strcpy(status_text, "Config save failed");
    else
        status_text[0] = '\0';
    return 0;
}