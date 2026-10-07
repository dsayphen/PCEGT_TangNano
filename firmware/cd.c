//
// CD-ROM emulation: CUE parsing, System Card loading, SCSI command service
// and CD-DA streaming.
//

#include "common.h"
#include "osd.h"
#include "settings.h"
#include "saves.h"
#include "rom.h"
#include "cd.h"
#include "cheats.h"
#include "fatfs/diskio.h"

static FIL cd_image;
static char cd_data_path[PWD_SIZE + NAME_MAX + 2];
static int cd_image_track = -1;     // data track whose file is open in cd_image
int cd_active = 0;

// All LBAs below are absolute disc LBAs (0 = track 1 INDEX 01 of a
// single-BIN image); the FILEs of a multi-BIN sheet are laid out back to back.
#define CD_MAX_TRACKS 40
static uint8_t  cd_track_is_data[CD_MAX_TRACKS];
static uint32_t cd_track_table_lba[CD_MAX_TRACKS];  // INDEX 01
static uint32_t cd_track_begin_lba[CD_MAX_TRACKS];  // INDEX 00, or INDEX 01 if absent
static uint32_t cd_track_file_lba[CD_MAX_TRACKS];   // byte 0 of the track's FILE
static uint16_t cd_track_sector_size[CD_MAX_TRACKS];
static uint8_t  cd_track_data_offset[CD_MAX_TRACKS];
static char     cd_track_filename[CD_MAX_TRACKS][NAME_MAX];
static int      cd_track_count = 0;
static int      cd_first_data_track = -1;
static uint32_t cd_disc_total_lba = 0;
static int      cd_stat_pending = 0;
int             cd_audio_playing = 0;
static int      cd_audio_paused = 0;
uint32_t        cd_audio_bytes_fed = 0;
uint32_t        cd_audio_read_ms = 0;
uint32_t        cd_audio_feed_ms = 0;
static uint32_t cd_audio_pos = 0;   // byte offset into cd_audio_file
static uint32_t cd_audio_start = 0;
static uint32_t cd_audio_end = 0;
static int      cd_audio_loop = 0;
static FIL      cd_audio_file;
static int      cd_audio_file_open = 0;
static int      cd_audio_cur_track = -1;

static int32_t cd_audio_command_lba(uint32_t cmd0, uint32_t cmd1, uint32_t cmd2) {
    uint32_t mode = (cmd2 >> 8) & 0xc0;
    if (mode == 0x80) {
        int track = from_bcd((uint8_t)(cmd0 >> 16));
        return track >= 1 && track <= cd_track_count
            ? (int32_t)cd_track_table_lba[track - 1] : -1;
    }
    if (mode == 0x40) {
        int minutes = from_bcd((uint8_t)(cmd0 >> 16));
        int seconds = from_bcd((uint8_t)(cmd0 >> 24));
        int frames = from_bcd((uint8_t)cmd1);
        if (minutes < 0 || seconds < 0 || seconds >= 60 ||
            frames < 0 || frames >= 75)
            return -1;
        int32_t absolute = (minutes * 60 + seconds) * 75 + frames;
        return absolute >= 150 ? absolute - 150 : 0;
    }
    if (mode == 0)
        return (int32_t)(((cmd0 >> 24) << 16) |
                         ((cmd1 & 0xff) << 8) | ((cmd1 >> 8) & 0xff));
    return -1;
}

static void frames_to_msf_bcd(uint32_t frame, uint8_t *m, uint8_t *s, uint8_t *f) {
    *m = to_bcd(frame / (60 * 75));
    *s = to_bcd((frame / 75) % 60);
    *f = to_bcd(frame % 75);
}

// standard Red Book LBA -> MSF, with the 2 second lead-in offset
static void lba_to_msf_bcd(uint32_t lba, uint8_t *m, uint8_t *s, uint8_t *f) {
    frames_to_msf_bcd(lba + 150, m, s, f);
}

void cd_audio_reset(void) {
    cd_audio_playing = 0;
    cd_audio_paused = 0;
    cd_audio_loop = 0;
    cd_audio_pos = 0;
    cd_audio_start = 0;
    cd_audio_end = 0;
    reg_cd_audio_hold = 1;
}

void cd_close(void) {
    if (cd_image_track >= 0)
        f_close(&cd_image);
    cd_image_track = -1;
    cd_active = 0;
}

static int cd_file_path(char *dst, size_t len, const char *name) {
    size_t used = 0;

    if (!dst || !name || len == 0)
        return -1;
    while (used < PWD_SIZE && pwd[used]) {
        if (used + 1 >= len)
            return -1;
        dst[used] = pwd[used];
        used++;
    }
    if (sd_trace_enabled)
        uart_print("cd: cwd copied\n");
    if (used == PWD_SIZE) {
        if (sd_trace_enabled)
            uart_print("cd: cwd invalid\n");
        return -1;
    }
    if (sd_trace_enabled)
        uart_print("cd: sep start\n");
    if (used > 1) {
        if (used + 1 >= len)
            return -1;
        dst[used++] = '/';
    }
    if (sd_trace_enabled)
        uart_print("cd: sep done\n");
    if (sd_trace_enabled)
        uart_print("cd: name start\n");
    while (*name) {
        if (used + 1 >= len)
            return -1;
        dst[used++] = *name++;
    }
    dst[used] = '\0';
    if (sd_trace_enabled)
        uart_printf("cd: name done len=%d\n", (int)used);
    return 0;
}

static uint32_t cd_file_frames(const char *name, uint32_t sector_size) {
    char path[PWD_SIZE + NAME_MAX + 2];
    FILINFO fno;

    if (cd_file_path(path, sizeof(path), name) != 0)
        return 0;
    if (f_stat(path, &fno) != FR_OK) {
        uart_printf("cd: cannot stat %s\n", path);
        return 0;
    }
    return (uint32_t)fno.fsize / sector_size;
}

static int cd_track_at(uint32_t lba) {
    int t = -1;
    for (int i = 0; i < cd_track_count; i++) {
        if (cd_track_filename[i][0] && cd_track_begin_lba[i] <= lba)
            t = i;
    }
    return t;
}

static int cd_data_track_at(uint32_t lba) {
    int t = -1;
    for (int i = 0; i < cd_track_count; i++) {
        if (cd_track_is_data[i] && cd_track_begin_lba[i] <= lba)
            t = i;
    }
    return t;
}

static int cd_open_data_track(int t) {
    if (cd_image_track == t)
        return 0;
    if (cd_image_track >= 0 &&
        strcmp(cd_track_filename[cd_image_track], cd_track_filename[t]) == 0) {
        cd_image_track = t;
        return 0;
    }
    if (cd_image_track >= 0)
        f_close(&cd_image);
    cd_image_track = -1;
    sd_trace_enabled = 1;
    uart_print("cd: path build begin\n");
    if (cd_file_path(cd_data_path, sizeof(cd_data_path),
                     cd_track_filename[t]) != 0) {
        uart_print("cd: path build FAILED\n");
        sd_trace_enabled = 0;
        return -1;
    }
    uart_print("cd: path build done\n");
    uart_print("cd: f_open call\n");
    FRESULT r = f_open(&cd_image, cd_data_path, FA_READ);
    sd_trace_enabled = 0;
    if (r != FR_OK) {
        uart_printf("cd: f_open failed, FRESULT=%d\n", (int)r);
        return -1;
    }
    cd_image_track = t;
    return 0;
}

// "MM:SS:FF" -> frames
static uint32_t parse_msf(const char *p) {
    uint32_t minutes = parse_u8(p);
    while (*p && *p != ':') p++;
    if (*p) p++;
    uint32_t seconds = parse_u8(p);
    while (*p && *p != ':') p++;
    if (*p) p++;
    uint32_t frames = parse_u8(p);
    return (minutes * 60 + seconds) * 75 + frames;
}

int is_cd_dir(const char *name) {
    int n = (int)strlen(name);
    return n >= 4 && strcasecmp(name + n - 4, "(CD)") == 0;
}

static int load_system_card(void) {
    static const char *names[] = {
        "/config/systemcard.pce",
        "/config/syscard.pce",
        "/config/system_card.pce",
        NULL
    };
    FIL f;
    UINT br;
    uint32_t total = 0;
    uint32_t size;
    uint32_t last_report = 0;
    int i;

    uart_print("syscard: searching /config\n");
    for (i = 0; names[i]; i++) {
        if (f_open(&f, names[i], FA_READ) == FR_OK)
            break;
    }
    if (!names[i]) {
        uart_print("syscard: not found\n");
        message("System Card missing", "Put it in /config");
        return -1;
    }

    size = (uint32_t)f_size(&f);
    uart_printf("syscard: opened %s, %d bytes\n", names[i], (int)size);
    if (size < ROM_MIN_SIZE || size > ROM_MAX_SIZE) {
        uart_print("syscard: invalid size\n");
        f_close(&f);
        message("Invalid System Card", "Use a PCE image");
        return -1;
    }

    status("Loading System Card...");
    uart_print("syscard: starting SDRAM transfer\n");
    pce_pause(1);
    pce_load_start(size, 0);
    cheats_clear();
    while (total < size) {
        UINT want = (UINT)((size - total) > sizeof(io_buf) ? sizeof(io_buf)
                                                               : (size - total));
        if (f_read(&f, io_buf, want, &br) != FR_OK || br == 0) {
            uart_printf("syscard: SD read error at %d bytes\n", (int)total);
            (void)pce_load_end();
            pce_pause(0);
            f_close(&f);
            message("System Card read error", names[i]);
            return -1;
        }

        total += br;
        while (br & 3)
            io_buf[br++] = 0xff;
        const uint32_t *w = (const uint32_t *)io_buf;
        for (UINT j = 0; j < br; j += 4)
            pce_load_word(*w++);

        if (total - last_report >= 65536 || total == size) {
            uart_printf("syscard: %d / %d bytes\n", (int)total, (int)size);
            last_report = total;
        }
    }

    f_close(&f);
    uart_print("syscard: transfer queued, waiting for SDRAM drain\n");
    if (pce_load_end() != 0) {
        pce_pause(0);
        message("System Card transfer timeout", names[i]);
        return -1;
    }
    uart_print("syscard: load request complete\n");
    return 0;
}

int open_cd_image(const char *cue_name) {
    FIL cue;
    char cue_path[PWD_SIZE + NAME_MAX + 2];
    char line[256];
    char current_file[NAME_MAX] = "";
    uint32_t file_base = 0;         // absolute LBA of byte 0 of current_file
    uint32_t file_sector = 2352;    // sector size of current_file's tracks
    int cur_track_num = 0;

    loading_status("Reading CD image...");
    strncpy(cue_path, pwd, sizeof(cue_path));
    if (cue_path[1] != '\0')
        strncat(cue_path, "/", sizeof(cue_path));
    strncat(cue_path, cue_name, sizeof(cue_path));

    if (f_open(&cue, cue_path, FA_READ) != FR_OK) {
        message("Invalid CUE file", cue_name);
        return -1;
    }

    cd_track_count = 0;
    cd_first_data_track = -1;
    while (f_gets(line, sizeof(line), &cue)) {
        char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;

        if (starts_with_ci_n(p, "FILE", 4)) {
            char *q = p + 4;
            while (*q == ' ' || *q == '\t') q++;
            if (*q == '"') {
                q++;
                char *end = q;
                while (*end && *end != '"') end++;
                if (*end == '"') {
                    *end = '\0';
                    // INDEX times restart at 0 in every FILE
                    if (current_file[0])
                        file_base += cd_file_frames(current_file, file_sector);
                    strncpy(current_file, q, sizeof(current_file) - 1);
                    current_file[sizeof(current_file) - 1] = '\0';
                }
            }
            continue;
        }

        if (starts_with_ci_n(p, "TRACK", 5)) {
            int is_data = contains_ci(p, "MODE1/2048") ||
                          contains_ci(p, "MODE1/2352") ||
                          contains_ci(p, "MODE2/2352");
            uint16_t sector_size = 2352;
            uint8_t data_offset = 0;

            if (contains_ci(p, "MODE1/2352"))
                data_offset = 16;
            else if (contains_ci(p, "MODE2/2352"))
                data_offset = 24;
            else if (contains_ci(p, "MODE1/2048"))
                sector_size = 2048;
            file_sector = sector_size;

            char *q = p + 5;
            while (*q == ' ' || *q == '\t') q++;
            cur_track_num = (int)parse_u8(q);
            if (cur_track_num >= 1 && cur_track_num <= CD_MAX_TRACKS) {
                int t = cur_track_num - 1;
                cd_track_is_data[t] = (uint8_t)is_data;
                cd_track_sector_size[t] = sector_size;
                cd_track_data_offset[t] = data_offset;
                cd_track_file_lba[t] = file_base;
                cd_track_begin_lba[t] = 0xffffffffu;
                cd_track_table_lba[t] = file_base;
                strncpy(cd_track_filename[t], current_file, NAME_MAX - 1);
                cd_track_filename[t][NAME_MAX - 1] = '\0';
                if (cur_track_num > cd_track_count)
                    cd_track_count = cur_track_num;
            }
            continue;
        }

        if (starts_with_ci_n(p, "INDEX", 5) &&
            cur_track_num >= 1 && cur_track_num <= CD_MAX_TRACKS) {
            int t = cur_track_num - 1;
            p += 5;
            while (*p == ' ' || *p == '\t')
                p++;
            int index = (int)parse_u8(p);
            while (*p >= '0' && *p <= '9')
                p++;
            while (*p == ' ' || *p == '\t')
                p++;
            uint32_t lba = file_base + parse_msf(p);

            if (index == 0) {
                cd_track_begin_lba[t] = lba;
            } else if (index == 1) {
                cd_track_table_lba[t] = lba;
                if (cd_track_begin_lba[t] == 0xffffffffu)
                    cd_track_begin_lba[t] = lba;
                if (cd_first_data_track < 0 && cd_track_is_data[t])
                    cd_first_data_track = t;
            }
        }
    }
    f_close(&cue);
    cd_disc_total_lba = current_file[0]
        ? file_base + cd_file_frames(current_file, file_sector) : 0;

    if (cd_first_data_track < 0) {
        message("No data track in CUE", cue_name);
        return -1;
    }

    extract_filename(current_game_name, cue_name);

    uart_printf("cd: %d tracks, %d sectors\n", cd_track_count, (int)cd_disc_total_lba);
    for (int i = 0; i < cd_track_count; i++)
        uart_printf("cd: track %d %s lba=%d file_lba=%d file=%s\n", i + 1,
                    cd_track_is_data[i] ? "DATA" : "AUDIO",
                    (int)cd_track_table_lba[i], (int)cd_track_file_lba[i],
                    cd_track_filename[i]);

    cd_close();
    if (cd_audio_file_open) {
        f_close(&cd_audio_file);
        cd_audio_file_open = 0;
        cd_audio_cur_track = -1;
    }
    if (load_system_card() != 0)
        return -1;
    if (cd_first_data_track < 0) {
        uart_print("cd: no DATA track found in CUE sheet\n");
        pce_pause(0);
        message("No data track in CUE", cue_name);
        return -1;
    }
    if (cheat_cd_enabled) {
        uart_print("cd: loading CD cheats\n");
        cheats_load(current_game_name, CHEAT_GAME_CD);
        uart_print("cd: cheats step done\n");
    }
    // status("Preparing CD..."); // ne pas afficher, trop rapide
    sd_trace_enabled = 1;
    uart_printf("cd: diag2 profile=%d status=%x track=%d\n",
                (int)CORE_PROFILE_ID, reg_romload_status,
                cd_first_data_track + 1);
    if (cd_open_data_track(cd_first_data_track) != 0) {
        uart_print("cd: data track open FAILED\n");
        cheats_clear();
        pce_pause(0);
        message("Cannot open CD image", cd_track_filename[cd_first_data_track]);
        return -1;
    }
    uart_print("cd: data track open ok\n");

    cd_stat_pending = 0;
    cd_active = 1;
    cd_audio_playing = 0;
    cd_audio_paused = 0;
    cd_audio_loop = 0;
    reg_cd_audio_hold = 1;
    current_game_populous = 0;
    reg_rom_pop = 0;
    game_pad_mode_load(current_game_name);
    uart_print("cd: pad mode loaded\n");
    load_game_saves(current_game_name, 0);
    pce_pause(1);
    uart_print("cd: saves step done\n");
    uart_print("cd: sending start request\n");
    pce_cd_start();
    return 0;
}

int find_cd_cue(char *cue_name, size_t cue_len) {
    DIR d;
    FILINFO fno;
    if (f_opendir(&d, pwd) != FR_OK)
        return -1;
    while (f_readdir(&d, &fno) == FR_OK && fno.fname[0]) {
        if (!(fno.fattrib & AM_DIR) && is_cue(fno.fname)) {
            strncpy(cue_name, fno.fname, cue_len - 1);
            cue_name[cue_len - 1] = '\0';
            f_closedir(&d);
            return 0;
        }
    }
    f_closedir(&d);
    return -1;
}

void cd_service(void) {
    static int service_logged = 0;
    static int first_data_seek_traced = 0;
    uint32_t events = reg_cd_events;
    if (!cd_active)
        return;
    if (!audio_cdda_enabled && cd_audio_playing) {
        cd_audio_playing = 0;
        cd_audio_paused = 1;
        cd_audio_loop = 0;
        reg_cd_audio_hold = 1;
    }
    if (!service_logged) {
        uart_print("cd: service active\n");
        service_logged = 1;
    }

    // CD-DA streaming: audio sectors are raw interleaved 16-bit stereo PCM,
    // no header to skip. Feed a modest chunk every poll so the CDDA FIFO's
    // half-full flag stays true and the game's audio wait loop can proceed.
    if (cd_audio_playing && cd_audio_pos >= cd_audio_end) {
        if (cd_audio_loop && cd_audio_start < cd_audio_end) {
            cd_audio_pos = cd_audio_start;
            uart_printf("cd: audio loop pos=%d\n", (int)cd_audio_pos);
        } else {
            cd_audio_playing = 0;
        }
    }

    if (cd_audio_playing && cd_audio_file_open && !(events & 0x20)) {
        UINT br;
        UINT want = (UINT)((cd_audio_end - cd_audio_pos) > sizeof(io_buf)
                           ? sizeof(io_buf) : (cd_audio_end - cd_audio_pos));
        uint32_t read_start = time_millis();
        FRESULT seek_result = f_tell(&cd_audio_file) == cd_audio_pos
            ? FR_OK : f_lseek(&cd_audio_file, cd_audio_pos);
        FRESULT read_result = seek_result == FR_OK
            ? f_read(&cd_audio_file, io_buf, want, &br)
            : seek_result;
        cd_audio_read_ms += time_millis() - read_start;
        if (read_result == FR_OK && br > 0) {
            uint32_t feed_start = time_millis();
            UINT i = 0;
            for (; i + 4 <= br; i += 4) {
                uint32_t word = (uint32_t)io_buf[i] |
                                ((uint32_t)io_buf[i + 1] << 8) |
                                ((uint32_t)io_buf[i + 2] << 16) |
                                ((uint32_t)io_buf[i + 3] << 24);
                reg_cd_audio_word = word;
            }
            for (; i < br; i++)
                reg_cd_feed = (uint32_t)io_buf[i];
            cd_audio_feed_ms += time_millis() - feed_start;
            cd_audio_pos += br;
            cd_audio_bytes_fed += br;
        } else {
            uart_printf("cd: audio stopped read=%d pos=%d size=%d\n",
                        (int)read_result, (int)cd_audio_pos,
                        (int)f_size(&cd_audio_file));
            cd_audio_playing = 0;
            cd_audio_paused = 0;
        }
    }

    // The SCSI core must fully drain any FIFO bytes pushed below before it
    // can be told status is ready; doing it earlier reorders phases and
    // confuses the BIOS driver.
    if (cd_stat_pending && (events & 0x04)) {
        reg_cd_ack = 0x04;
        reg_cd_stat = 0;
        cd_stat_pending = 0;
    }

    if (events & 0x10)
        reg_cd_ack = 0x10;

    if (events & 0x01) {
        uint32_t cmd0 = reg_cd_cmd0;
        uint32_t cmd1 = reg_cd_cmd1;
        uint32_t opcode = cmd0 & 0xff;
        uint32_t lba = ((cmd0 >> 8) & 0x1f) << 16 |
                       (cmd0 >> 16 & 0xff) << 8 |
                       (cmd0 >> 24 & 0xff);
        uint32_t count = cmd1 & 0xff;
            if (opcode == 0x08 && count == 0)
            count = 256;

        int pushed_data = 0;

        if (opcode == 0x08 && count != 0) {
            int ok = 1;
            for (uint32_t s = 0; s < count; s++) {
                uint32_t sector = lba + s;
                int t = cd_data_track_at(sector);
                uint32_t frame;
                if (t >= 0) {
                    frame = sector - cd_track_file_lba[t];
                } else {
                    // before the first data track: relative to its INDEX 01
                    t = cd_first_data_track;
                    frame = cd_track_table_lba[t] - cd_track_file_lba[t] + sector;
                }
                if (cd_open_data_track(t) != 0) {
                    uart_printf("cd: cannot open track %d\n", t + 1);
                    ok = 0;
                    break;
                }
                uint32_t offset = frame * cd_track_sector_size[t] +
                                  cd_track_data_offset[t];
                UINT br;
                sd_trace_enabled = !first_data_seek_traced;
                FRESULT seek_result = f_lseek(&cd_image, offset);
                sd_trace_enabled = 0;
                first_data_seek_traced = 1;
                if (seek_result != FR_OK) {
                    uart_printf("cd: seek failed res=%d offset=%d size=%d pos=%d\n",
                                (int)seek_result, (int)offset,
                                (int)f_size(&cd_image), (int)f_tell(&cd_image));
                    ok = 0;
                    break;
                }
                FRESULT read_result = f_read(&cd_image, io_buf, 2048, &br);
                if (read_result != FR_OK || br != 2048) {
                    uart_printf("cd: short read at sector %d\n", (int)sector);
                    ok = 0;
                    break;
                }
                for (UINT i = 0; i < br; i++)
                    reg_cd_feed = (uint32_t)io_buf[i] | 0x100;

                // the SCSI FIFO only holds one sector; without waiting here
                // the next sector's bytes overrun it and get silently lost
                if (s + 1 < count) {
                    uint32_t t0 = time_millis();
                    while (!(reg_cd_events & 0x04)) {
                        if (time_millis() - t0 > 50)
                            break;
                    }
                    reg_cd_ack = 0x04;
                }
            }
            pushed_data = ok;
        } else if (opcode == 0xdd) {
            uint8_t subq[10];
            uint8_t rel_m, rel_s, rel_f, abs_m, abs_s, abs_f;
            int track = cd_audio_cur_track >= 0 ? cd_audio_cur_track : 0;
            uint32_t used = reg_cd_usedw;
            uint32_t played = cd_audio_pos > used ? cd_audio_pos - used : 0;
            uint32_t frame = cd_track_file_lba[track] + played / 2352;
            uint32_t track_lba = cd_track_table_lba[track];
            if (frame < track_lba)
                frame = track_lba;
            frames_to_msf_bcd(frame - track_lba, &rel_m, &rel_s, &rel_f);
            lba_to_msf_bcd(frame, &abs_m, &abs_s, &abs_f);
            subq[0] = cd_audio_paused ? 2 : cd_audio_playing ? 0 : 3;
            subq[1] = 0x01 | ((track + 1 < cd_track_count &&
                                cd_track_is_data[track + 1]) ? 0x40 : 0);
            subq[2] = to_bcd((uint32_t)track + 1);
            subq[3] = 1;
            subq[4] = rel_m;
            subq[5] = rel_s;
            subq[6] = rel_f;
            subq[7] = abs_m;
            subq[8] = abs_s;
            subq[9] = abs_f;
            for (int i = 0; i < 10; i++)
                reg_cd_feed = (uint32_t)subq[i] | 0x100;
            pushed_data = 1;
        } else if (opcode == 0xde) {
            // NEC GET_DIR_INFO: COMM(1) selects the sub-function.
            uint32_t sub = (cmd0 >> 8) & 0xff;
            if (sub == 0x00) {
                reg_cd_feed = (uint32_t)to_bcd(1) | 0x100;
                reg_cd_feed = (uint32_t)to_bcd((uint32_t)cd_track_count) | 0x100;
                pushed_data = 1;
            } else if (sub == 0x01) {
                uint8_t m, s, f;
                lba_to_msf_bcd(cd_disc_total_lba, &m, &s, &f);
                reg_cd_feed = (uint32_t)m | 0x100;
                reg_cd_feed = (uint32_t)s | 0x100;
                reg_cd_feed = (uint32_t)f | 0x100;
                pushed_data = 1;
            } else if (sub == 0x02 && cd_track_count > 0) {
                uint32_t track_bcd = (cmd0 >> 16) & 0xff;
                uint32_t track_no = ((track_bcd >> 4) * 10) + (track_bcd & 0xf);
                if (track_no < 1) track_no = 1;
                if (track_no > (uint32_t)cd_track_count) track_no = (uint32_t)cd_track_count;
                uint8_t m, s, f;
                lba_to_msf_bcd(cd_track_table_lba[track_no - 1], &m, &s, &f);
                reg_cd_feed = (uint32_t)m | 0x100;
                reg_cd_feed = (uint32_t)s | 0x100;
                reg_cd_feed = (uint32_t)f | 0x100;
                reg_cd_feed = (uint32_t)(cd_track_is_data[track_no - 1] ? 0x04 : 0x00) | 0x100;
                pushed_data = 1;
            }
        }

        if (opcode == 0xd8) {
            uint32_t cmd2 = reg_cd_cmd2;
            int32_t requested_lba = cd_audio_command_lba(cmd0, cmd1, cmd2);
            int t = -1;

            if (((cmd2 >> 8) & 0xc0) == 0x80) {
                int track = from_bcd((uint8_t)(cmd0 >> 16));
                if (track >= 1 && track <= cd_track_count)
                    t = track - 1;
            } else if (requested_lba > 0) {
                t = cd_track_at((uint32_t)requested_lba);
            } else if (requested_lba == 0) {
                for (int i = 0; i < cd_track_count; i++) {
                    if (!cd_track_is_data[i] && cd_track_filename[i][0]) {
                        t = i;
                        requested_lba = (int32_t)cd_track_table_lba[i];
                        break;
                    }
                }
            }

            if (t >= 0 && cd_track_is_data[t])
                t = -1;
            if (t >= 0 && cd_audio_cur_track != t) {
                if (cd_audio_file_open)
                    f_close(&cd_audio_file);
                char apath[PWD_SIZE + NAME_MAX + 2];
                cd_audio_file_open = cd_file_path(apath, sizeof(apath),
                                                  cd_track_filename[t]) == 0 &&
                    f_open(&cd_audio_file, apath, FA_READ) == FR_OK;
                cd_audio_cur_track = cd_audio_file_open ? t : -1;
            }

            cd_audio_playing = 0;
            cd_audio_paused = 0;
            cd_audio_loop = 0;
            reg_cd_audio_hold = 1;
            if (t >= 0 && cd_audio_file_open) {
                uint32_t ss = cd_track_sector_size[t];
                uint32_t base = cd_track_file_lba[t];
                cd_audio_pos = (uint32_t)requested_lba > base
                    ? ((uint32_t)requested_lba - base) * ss : 0;
                cd_audio_start = cd_audio_pos;
                cd_audio_end = (uint32_t)f_size(&cd_audio_file);
                if (t + 1 < cd_track_count &&
                    strcmp(cd_track_filename[t], cd_track_filename[t + 1]) == 0 &&
                    cd_track_table_lba[t + 1] > (uint32_t)requested_lba) {
                    uint32_t next_track = (cd_track_table_lba[t + 1] - base) * ss;
                    if (next_track < cd_audio_end)
                        cd_audio_end = next_track;
                }
                cd_audio_loop = (cmd0 >> 8 & 3) == 1;
                cd_audio_playing = audio_cdda_enabled &&
                                   (cmd0 >> 8 & 3) != 0 && cd_audio_pos < cd_audio_end;
                cd_audio_paused = !cd_audio_playing;
            }
            uart_printf("cd: sapsp track=%d lba=%d play=%d\n",
                        t + 1, (int)requested_lba, cd_audio_playing);
            int iter = 0;
            if (cd_audio_playing) {
                f_lseek(&cd_audio_file, cd_audio_pos);
                for (iter = 0; iter < 32; iter++) {
                    if ((reg_cd_events & 0x20) || cd_audio_pos >= cd_audio_end)
                        break;
                    UINT br;
                    UINT want = (UINT)((cd_audio_end - cd_audio_pos) > sizeof(io_buf)
                                       ? sizeof(io_buf) : (cd_audio_end - cd_audio_pos));
                    if (f_read(&cd_audio_file, io_buf, want, &br) != FR_OK || br == 0)
                        break;
                    UINT i = 0;
                    for (; i + 4 <= br; i += 4) {
                        uint32_t word = (uint32_t)io_buf[i] |
                                        ((uint32_t)io_buf[i + 1] << 8) |
                                        ((uint32_t)io_buf[i + 2] << 16) |
                                        ((uint32_t)io_buf[i + 3] << 24);
                        reg_cd_audio_word = word;
                    }
                    for (; i < br; i++)
                        reg_cd_feed = (uint32_t)io_buf[i];
                    cd_audio_pos += br;
                }
            }
            reg_cd_audio_hold = !cd_audio_playing;
            uart_printf("cd: sapsp fed iter=%d, halffull=%d usedw=%d adpcm=%x\n",
                        iter, (reg_cd_events & 0x20) ? 1 : 0, (int)reg_cd_usedw,
                        (unsigned)reg_cd_adpcm);
        } else if (opcode == 0xd9) {
            int32_t end_lba = cd_audio_command_lba(cmd0, cmd1, reg_cd_cmd2);
            if (end_lba >= 0 && cd_audio_file_open) {
                uint32_t base = cd_track_file_lba[cd_audio_cur_track];
                cd_audio_end = (uint32_t)end_lba > base
                    ? ((uint32_t)end_lba - base) *
                      cd_track_sector_size[cd_audio_cur_track] : 0;
                if (cd_audio_end > (uint32_t)f_size(&cd_audio_file))
                    cd_audio_end = (uint32_t)f_size(&cd_audio_file);
            }
            cd_audio_loop = (cmd0 >> 8 & 3) == 1;
            cd_audio_playing = audio_cdda_enabled &&
                               (cmd0 >> 8 & 3) != 0 && cd_audio_file_open &&
                               (cd_audio_pos < cd_audio_end ||
                                (cd_audio_loop && cd_audio_start < cd_audio_end));
            cd_audio_paused = 0;
            reg_cd_audio_hold = !cd_audio_playing;
            uart_printf("cd: sapep end=%d play=%d\n", (int)end_lba, cd_audio_playing);
        } else if (opcode == 0xda) {
            uart_printf("cd: audio stopped opcode=%x pos=%d\n",
                        (unsigned)opcode, (int)cd_audio_pos);
            cd_audio_playing = 0;
            cd_audio_paused = 1;
            cd_audio_loop = 0;
            reg_cd_audio_hold = 1;
        }

        reg_cd_ack = 0x01;
        if (pushed_data)
            cd_stat_pending = 1;
        else
            reg_cd_stat = 0;
    }
}
