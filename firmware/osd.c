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

void title(void) {
    clear_line(ROW_TITLE);
    cursor(1, ROW_TITLE);
    print("PCEngine - pick a ROM");
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
