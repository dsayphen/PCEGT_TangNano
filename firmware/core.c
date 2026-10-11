#include "common.h"
#include "osd.h"
#include "rom.h"
#include "cd.h"
#include "core.h"

#define SLOT_SIZE 0x100000u
#define SECTOR_SIZE 4096u
#define MANIFEST_OFFSET (SLOT_SIZE - 32u)
#define CORE_MAGIC 0x50434543u
#define AUTORUN_MAGIC 0x41555431u
#define AUTORUN_PATH "/config/core_autorun.dat"

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t profile;
    uint32_t size;
    uint32_t crc;
} CoreManifest;

typedef struct {
    uint32_t magic;
    uint32_t profile;
    char directory[PWD_SIZE];
    char game[NAME_MAX];
    uint32_t crc;
} Autorun;

static uint8_t sector_buf[SECTOR_SIZE];
static Autorun autorun;

const char *core_name(uint32_t profile) {
    switch (profile) {
    case CORE_PROFILE_SGX: return "HuCard";
    case CORE_PROFILE_CD: return "CD-Rom";
    case CORE_PROFILE_SUPERSET: return "Superset";
    default: return "Unknown";
    }
}

static uint32_t crc_byte(uint32_t crc, uint8_t value) {
    crc ^= value;
    for (int bit = 0; bit < 8; bit++)
        crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
    return crc;
}

static uint32_t buffer_crc(const void *buffer, uint32_t length) {
    const uint8_t *bytes = buffer;
    uint32_t crc = 0xffffffffu;
    for (uint32_t index = 0; index < length; index++)
        crc = crc_byte(crc, bytes[index]);
    return ~crc;
}

static int flash_byte(uint8_t value) {
    uint32_t started = time_millis();
    reg_flash_data = value;
    while (reg_flash_ctrl & 1u) {
        if ((uint32_t)(time_millis() - started) >= 50u)
            return -1;
    }
    return (int)(reg_flash_data & 0xffu);
}

static int flash_command(uint8_t command) {
    reg_flash_ctrl = 2;
    return flash_byte(command) < 0 ? -1 : 0;
}

static void flash_end(void) {
    reg_flash_ctrl = 3;
}

static int flash_address(uint8_t command, uint32_t address) {
    if (flash_command(command) != 0 ||
        flash_byte(address >> 16) < 0 ||
        flash_byte(address >> 8) < 0 || flash_byte(address) < 0) {
        flash_end();
        return -1;
    }
    return 0;
}

static int flash_read(uint32_t address, void *buffer, uint32_t length) {
    uint8_t *bytes = buffer;
    if (flash_address(0x03, address) != 0)
        return -1;
    for (uint32_t index = 0; index < length; index++) {
        int value = flash_byte(0);
        if (value < 0) {
            flash_end();
            return -1;
        }
        bytes[index] = (uint8_t)value;
    }
    flash_end();
    return 0;
}

static int flash_status(void) {
    int value = -1;
    if (flash_command(0x05) == 0)
        value = flash_byte(0);
    flash_end();
    return value;
}

static int flash_wait(uint32_t timeout) {
    uint32_t started = time_millis();
    for (;;) {
        int value = flash_status();
        if (value < 0)
            return -1;
        if (!(value & 1))
            return 0;
        if ((uint32_t)(time_millis() - started) >= timeout)
            return -1;
    }
}

static int flash_write_enable(void) {
    int result = flash_command(0x06);
    flash_end();
    if (result != 0)
        return -1;
    int value = flash_status();
    return value >= 0 && (value & 2) && !(value & 0x7c) ? 0 : -1;
}

static int flash_erase(uint32_t address) {
    if (address >= SLOT_SIZE || (address & (SECTOR_SIZE - 1)) ||
        flash_write_enable() != 0)
        return -1;
    int result = flash_address(0x20, address);
    flash_end();
    return result == 0 ? flash_wait(3000) : -1;
}

static int flash_page(uint32_t address, const uint8_t *bytes) {
    if (address >= SLOT_SIZE || (address & 255u) ||
        flash_write_enable() != 0 || flash_address(0x02, address) != 0)
        return -1;
    for (uint32_t index = 0; index < 256; index++) {
        if (flash_byte(bytes[index]) < 0) {
            flash_end();
            return -1;
        }
    }
    flash_end();
    return flash_wait(100);
}

static int flash_verify(uint32_t address, const uint8_t *bytes) {
    if (flash_address(0x03, address) != 0)
        return -1;
    for (uint32_t index = 0; index < SECTOR_SIZE; index++) {
        int value = flash_byte(0);
        if (value < 0 || value != bytes[index]) {
            flash_end();
            return -1;
        }
    }
    flash_end();
    return 0;
}

static void flash_release(void) {
    flash_end();
    flash_command(0x04);
    flash_end();
    reg_flash_ctrl = 1;
}

static int confirm_switch(uint32_t profile) {
    clear();
    print_field(1, 6, "Switch core to:", OSD_COLS - 2);
    print_field(1, 8, core_name(profile), OSD_COLS - 2);
    print_field(1, 10, "Do not power off while copying", OSD_COLS - 2);
    print_field(1, 12, "Power cycle needed afterwards", OSD_COLS - 2);
    status("A=Confirm  B=Cancel");
    delay(250);
    for (;;) {
        uint32_t edge = joy_edge();
        if (edge & JOY_B)
            return 0;
        if (edge & JOY_A)
            return 1;
        delay(10);
    }
}

static int clear_autorun(void) {
    FRESULT result = f_unlink(AUTORUN_PATH);
    return result == FR_OK || result == FR_NO_FILE || result == FR_NO_PATH ? 0 : -1;
}

static int save_autorun(uint32_t profile, const char *game) {
    FIL file;
    UINT written;
    if (clear_autorun() != 0)
        return -1;
    if (!game)
        return 0;
    memset(&autorun, 0, sizeof(autorun));
    autorun.magic = AUTORUN_MAGIC;
    autorun.profile = profile;
    strcpy(autorun.directory, pwd);
    strncpy(autorun.game, game, NAME_MAX - 1);
    autorun.crc = buffer_crc(&autorun, sizeof(autorun) - sizeof(autorun.crc));
    FRESULT result = f_mkdir("/config");
    if (result != FR_OK && result != FR_EXIST)
        return -1;
    if (f_open(&file, AUTORUN_PATH, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK)
        return -1;
    result = f_write(&file, &autorun, sizeof(autorun), &written);
    FRESULT closed = f_close(&file);
    if (result != FR_OK || written != sizeof(autorun) || closed != FR_OK) {
        clear_autorun();
        return -1;
    }
    return 0;
}

int core_offer_switch(uint32_t profile, const char *game) {
    CoreManifest manifest;
    uint8_t identity[3];
    int modified = 0;
    if (profile < CORE_PROFILE_SGX || profile > CORE_PROFILE_SUPERSET)
        return 0;
    if (!confirm_switch(profile))
        return 0;
    if ((reg_flash_ctrl >> 16) != 0x4653u) {
        message("Core switching unavailable", "Rebuild all three cores");
        return 0;
    }
    reg_flash_ctrl = 3;
    status("Checking SPI flash...");
    if (flash_wait(3000) != 0 || flash_command(0x9f) != 0)
        goto failed;
    for (int index = 0; index < 3; index++) {
        int value = flash_byte(0);
        if (value < 0)
            goto failed;
        identity[index] = (uint8_t)value;
    }
    flash_end();
    if (!identity[0] || identity[0] == 255 || identity[2] < 0x17 || identity[2] > 0x19)
        goto failed;
    uint32_t source = profile * SLOT_SIZE;
    if (flash_read(source + MANIFEST_OFFSET, &manifest, sizeof(manifest)) != 0 ||
        manifest.magic != CORE_MAGIC || manifest.version != 1 ||
        manifest.profile != profile || manifest.size == 0 ||
        manifest.size > MANIFEST_OFFSET)
        goto failed;
    uint32_t crc = 0xffffffffu;
    for (uint32_t offset = 0; offset < manifest.size; offset += SECTOR_SIZE) {
        uint32_t length = manifest.size - offset;
        if (length > SECTOR_SIZE)
            length = SECTOR_SIZE;
        if (flash_read(source + offset, sector_buf, length) != 0)
            goto failed;
        for (uint32_t index = 0; index < length; index++)
            crc = crc_byte(crc, sector_buf[index]);
        clear_line(ROW_STATUS);
        cursor(1, ROW_STATUS);
        printf("Checking core %d%%", (int)((offset + length) * 100 / manifest.size));
    }
    if (~crc != manifest.crc)
        goto failed;
    if (save_autorun(profile, game) != 0) {
        flash_release();
        message("Cannot save autorun", "Check SD card /config");
        return 0;
    }
    pce_pause(1);
    cd_audio_reset();
    cd_close();
    for (uint32_t offset = 0; offset < SLOT_SIZE; offset += SECTOR_SIZE) {
        if (flash_read(source + offset, sector_buf, SECTOR_SIZE) != 0)
            goto failed;
        modified = 1;
        if (flash_erase(offset) != 0)
            goto failed;
        for (uint32_t page = 0; page < SECTOR_SIZE; page += 256) {
            if (flash_page(offset + page, sector_buf + page) != 0)
                goto failed;
        }
        if (flash_verify(offset, sector_buf) != 0)
            goto failed;
        clear_line(ROW_STATUS);
        cursor(1, ROW_STATUS);
        printf("Copying core %d%%", (int)((offset + SECTOR_SIZE) * 100 / SLOT_SIZE));
    }
    flash_release();
    clear();
    print_field(1, 8, "Core ready", OSD_COLS - 2);
    print_field(1, 9, core_name(profile), OSD_COLS - 2);
    status("Power off, then power on");
    for (;;) delay(100);

failed:
    flash_release();
    clear_autorun();
    if (modified) {
        clear();
        print_field(1, 6, "Core copy failed", OSD_COLS - 2);
        print_field(1, 8, "Boot image may be damaged", OSD_COLS - 2);
        status("Restore flash via programmer");
        for (;;) delay(100);
    }
    message("Invalid flash/core slot", "Boot image left unchanged");
    return 0;
}

void core_menu(void) {
    int active = 0;
    for (;;) {
        clear();
        print_field(3, 5, "Choose core", OSD_COLS - 3);
        for (int index = 0; index < 3; index++) {
            uint32_t profile = index + CORE_PROFILE_SGX;
            cursor(2, 8 + index);
            putchar(index == active ? '>' : ' ');
            print_field(4, 8 + index, core_name(profile), 16);
            if (profile == CORE_PROFILE_ID)
                print_field(21, 8 + index, "Active", 6);
        }
        selection_row(8 + active);
        status("A=Select  B=Back");
        for (;;) {
            uint32_t edge = joy_edge();
            if (edge & (JOY_B | JOY_SELECT))
                return;
            if (edge & JOY_UP) {
                active = active ? active - 1 : 2;
                break;
            }
            if (edge & JOY_DOWN) {
                active = active == 2 ? 0 : active + 1;
                break;
            }
            if (edge & JOY_A) {
                uint32_t profile = active + CORE_PROFILE_SGX;
                if (profile != CORE_PROFILE_ID)
                    core_offer_switch(profile, NULL);
                break;
            }
            delay(10);
        }
    }
}

int core_autorun(void) {
    FIL file;
    UINT read;
    if (f_open(&file, AUTORUN_PATH, FA_READ) != FR_OK)
        return 0;
    FRESULT result = f_read(&file, &autorun, sizeof(autorun), &read);
    FSIZE_t size = f_size(&file);
    FRESULT closed = f_close(&file);
    if (clear_autorun() != 0) {
        message("Cannot consume autorun", "Check SD card /config");
        return 0;
    }
    if (result != FR_OK || closed != FR_OK || read != sizeof(autorun) ||
        size != sizeof(autorun) || autorun.magic != AUTORUN_MAGIC ||
        autorun.profile != CORE_PROFILE_ID ||
        autorun.directory[0] != '/' || autorun.directory[PWD_SIZE - 1] != 0 ||
        autorun.game[0] == 0 || autorun.game[NAME_MAX - 1] != 0 ||
        strchr(autorun.game, '/') || strchr(autorun.game, '\\') ||
        autorun.crc != buffer_crc(&autorun, sizeof(autorun) - sizeof(autorun.crc)) ||
        (is_cue(autorun.game) ? CORE_PROFILE_ID == CORE_PROFILE_SGX :
         !is_rom(autorun.game) || CORE_PROFILE_ID == CORE_PROFILE_CD)) {
        message("Autorun cancelled", "Invalid request or wrong core");
        return 0;
    }
    strcpy(pwd, autorun.directory);
    int loaded;
    if (is_cue(autorun.game)) {
        loaded = open_cd_image(autorun.game);
    } else {
        char path[PWD_SIZE + NAME_MAX + 2];
        FILINFO info;
        strcpy(path, pwd);
        if (pwd[1])
            strcat(path, "/");
        strcat(path, autorun.game);
        loaded = f_stat(path, &info) == FR_OK && !(info.fattrib & AM_DIR)
            ? load_rom(autorun.game, (uint32_t)info.fsize) : -1;
    }
    if (loaded != 0) {
        message("Autorun failed", autorun.game);
        return 0;
    }
    overlay(0);
    return 1;
}