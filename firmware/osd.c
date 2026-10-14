//
// Small OSD helpers.
//

#include "common.h"
#include "osd.h"

void status(const char *msg) {
    clear_line(ROW_STATUS);
    cursor(1, ROW_STATUS);
    print(msg);
}

void loading_status(const char *msg) {
    clear();
    selection_row(31);
    status(msg);
}

void progress_bar(int percent) {
    const int blocks = OSD_COLS - 2;
    if (percent < 0)
        percent = 0;
    if (percent > 100)
        percent = 100;
    int filled = percent * blocks / 100;

    clear_line(ROW_PROGRESS + 1);
    cursor(0, ROW_PROGRESS_BAR);
    putchar(' ');
    for (int block = 0; block < blocks; block++)
        putchar(block < filled ? '_' : '$');
    putchar(' ');
}

void progress_status(const char *msg, int percent) {
    if (percent < 0)
        percent = 0;
    if (percent > 100)
        percent = 100;
    cursor(1, ROW_PROGRESS);
    printf("%s %d%%", msg, percent);
    int text_len = (int)strlen(msg) + (percent >= 100 ? 5 : percent >= 10 ? 4 : 3);
    for (int column = 1 + text_len; column < OSD_COLS; column++)
        putchar(' ');
    progress_bar(percent);
}

void title(void) {
    const char *profile;

    switch (CORE_PROFILE_ID) {
    case CORE_PROFILE_PCE:
        profile = "PCEngine";
        break;
    case CORE_PROFILE_SGX:
        profile = "HuCard";
        break;
    case CORE_PROFILE_CD:
        profile = "CD-ROM";
        break;
    case CORE_PROFILE_SUPERSET:
        profile = "Superset";
        break;
    default:
        profile = "Unknown core";
        break;
    }

    clear_line(ROW_TITLE);
    cursor(1, ROW_TITLE);
    print(profile);
    putchar(' ');
    int path_column = 2 + (int)strlen(profile);
    print_field(path_column, ROW_TITLE, pwd, OSD_COLS - 1 - path_column);
}

// Print a string right-truncated to `w` columns starting at column x.
void print_field(int x, int y, const char *s, int w) {
    cursor(x, y);
    int i = 0;
    while (s[i] && i < w) {
        putchar(s[i]);
        i++;
    }
    while (i < w) {
        putchar(' ');
        i++;
    }
}

// Wait for A or B, used by the error pop-ups.
static void wait_button(void) {
    delay(250);
    for (;;) {
        uint32_t e = joy_edge();
        if (e & (JOY_A | JOY_B | JOY_START))
            break;
    }
    delay(150);
}

void message(const char *l1, const char *l2) {
    clear();
    title();
    print_field(1, 8, l1, OSD_COLS - 2);
    if (l2)
        print_field(1, 9, l2, OSD_COLS - 2);
    status("Press A to continue");
    wait_button();
}
