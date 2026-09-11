//
// Minimal C runtime for the PicoRV32 IO subsystem of the Tang Nano 20K
// PC Engine port: OSD text output, UART debug output, joypad edge detection
// and the handful of string / memory routines FatFs needs.
//
// Derived from nand2mario's SNESTang firmware/picorv32.c, tag v0.7
// (commit df5acd0104d0a6a2c8c22e8e4857baf61d456aaa), GPLv3.
//

#include "picorv32.h"
#include <stdarg.h>

// ===========================================================================
// OSD text output
// ===========================================================================
static int curx, cury;
static int overlay_on = 1;

void cursor(int x, int y) {
    curx = x;
    cury = y;
}

void overlay(int on) {
    reg_textdisp = on ? 0x01000000 : 0x02000000;
    overlay_on = on;
}

int overlay_status(void) {
    return overlay_on;
}

void selection_row(int y) {
    reg_textdisp = 0x03000000 | ((uint32_t)(y & 31) << 8);
}

int putchar(int c) {
    if (c == '\n') {
        curx = 0;
        cury++;
        return c;
    }
    if (curx >= 0 && curx < OSD_COLS && cury >= 0 && cury < OSD_ROWS) {
        reg_textdisp = ((uint32_t)curx << 16) | ((uint32_t)cury << 8) | (c & 0xff);
        curx++;
    }
    return c;
}

int print(const char *p) {
    while (*p)
        putchar(*p++);
    return 0;
}

void clear_line(int y) {
    cursor(0, y);
    for (int i = 0; i < OSD_COLS; i++)
        putchar(' ');
}

void clear(void) {
    for (int y = 0; y < OSD_ROWS; y++)
        clear_line(y);
    cursor(0, 0);
}

// ===========================================================================
// UART
// ===========================================================================
void uart_init(int clkdiv) {
    reg_uart_clkdiv = clkdiv;
}

int uart_putchar(int c) {
    if (c == '\n')
        reg_uart_data = '\r';
    reg_uart_data = c;
    return c;
}

int uart_print(const char *s) {
    while (*s)
        uart_putchar(*s++);
    return 0;
}

// ===========================================================================
// Shared formatting
// ===========================================================================
static int _putchar(int c, int uart) {
    return uart ? uart_putchar(c) : putchar(c);
}

static void _print(const char *s, int uart) {
    while (*s)
        _putchar(*s++, uart);
}

static void _print_hex_digits(uint32_t val, int nbdigits, int uart) {
    for (int i = (4 * nbdigits) - 4; i >= 0; i -= 4)
        _putchar("0123456789ABCDEF"[(val >> i) & 0xf], uart);
}

static void _print_dec(int val, int uart) {
    char buffer[12];
    char *p = buffer;
    if (val < 0) {
        _putchar('-', uart);
        val = -val;
    }
    do {
        *p++ = (char)('0' + (val % 10));
        val /= 10;
    } while (val);
    while (p != buffer)
        _putchar(*--p, uart);
}

static void _printf(const char *fmt, va_list ap, int uart) {
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            _putchar(*fmt, uart);
            continue;
        }
        fmt++;
        switch (*fmt) {
            case 's': _print(va_arg(ap, char *), uart); break;
            case 'x': _print_hex_digits(va_arg(ap, uint32_t), 8, uart); break;
            case 'd': _print_dec(va_arg(ap, int), uart); break;
            case 'c': _putchar(va_arg(ap, int), uart); break;
            case 'b': _print_hex_digits(va_arg(ap, uint32_t), 2, uart); break;
            case 'w': _print_hex_digits(va_arg(ap, uint32_t), 4, uart); break;
            case '\0': return;
            default:  _putchar(*fmt, uart); break;
        }
    }
}

void print_hex_digits(uint32_t v, int n) { _print_hex_digits(v, n, 0); }
void print_hex(uint32_t v)               { _print_hex_digits(v, 8, 0); }
void print_dec(int v)                    { _print_dec(v, 0); }
void uart_print_hex_digits(uint32_t v, int n) { _print_hex_digits(v, n, 1); }
void uart_print_hex(uint32_t v)          { _print_hex_digits(v, 8, 1); }
void uart_print_dec(int v)               { _print_dec(v, 1); }

int printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    _printf(fmt, ap, 0);
    va_end(ap);
    return 0;
}

int uart_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    _printf(fmt, ap, 1);
    va_end(ap);
    return 0;
}

// ===========================================================================
// Time
// ===========================================================================
void delay(int ms) {
    uint32_t t0 = time_millis();
    while ((uint32_t)(time_millis() - t0) < (uint32_t)ms) { }
}

// ===========================================================================
// Joypad
//
// joy_edge() reports buttons that have just been pressed.  The four d-pad
// directions auto-repeat so that holding a direction scrolls the file list.
// ===========================================================================
uint32_t joy_raw(void) {
    return reg_joystick & 0xfff;
}

#define REPEAT_DELAY  380       // ms before auto-repeat starts
#define REPEAT_PERIOD  90       // ms between repeats

uint32_t joy_edge(void) {
    static uint32_t prev = 0;
    static uint32_t repeat_at = 0;
    static uint32_t held = 0;

    uint32_t now = joy_raw();
    uint32_t edge = now & ~prev;
    uint32_t t = time_millis();

    uint32_t dpad = now & (JOY_UP | JOY_DOWN | JOY_LEFT | JOY_RIGHT);
    if (dpad == 0) {
        held = 0;
    } else if (dpad != held) {
        held = dpad;
        repeat_at = t + REPEAT_DELAY;
    } else if ((int32_t)(t - repeat_at) >= 0) {
        edge |= dpad;
        repeat_at = t + REPEAT_PERIOD;
    }

    prev = now;
    return edge;
}

// ===========================================================================
// Tiny libc
// ===========================================================================
void *memcpy(void *dst, const void *src, size_t len) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;

    if ((((uintptr_t)d | (uintptr_t)s) & 3) == 0) {
        uint32_t *dw = (uint32_t *)dst;
        const uint32_t *sw = (const uint32_t *)src;
        while (len >= 4) {
            *dw++ = *sw++;
            len -= 4;
        }
        d = (uint8_t *)dw;
        s = (const uint8_t *)sw;
    }
    while (len--)
        *d++ = *s++;
    return dst;
}

void *memset(void *s, int c, size_t n) {
    uint8_t *p = (uint8_t *)s;
    uint8_t v = (uint8_t)c;

    while (n && (((uintptr_t)p) & 3)) {
        *p++ = v;
        n--;
    }
    uint32_t w = ((uint32_t)v << 24) | ((uint32_t)v << 16) | ((uint32_t)v << 8) | v;
    uint32_t *pw = (uint32_t *)p;
    while (n >= 4) {
        *pw++ = w;
        n -= 4;
    }
    p = (uint8_t *)pw;
    while (n--)
        *p++ = v;
    return s;
}

int memcmp(const void *s1, const void *s2, size_t n) {
    const uint8_t *p1 = (const uint8_t *)s1;
    const uint8_t *p2 = (const uint8_t *)s2;
    for (size_t i = 0; i < n; i++) {
        if (p1[i] != p2[i])
            return p1[i] < p2[i] ? -1 : 1;
    }
    return 0;
}

size_t strlen(const char *s) {
    size_t r = 0;
    while (*s++)
        r++;
    return r;
}

int strcmp(const char *s1, const char *s2) {
    while (*s1 && (*s1 == *s2)) {
        s1++;
        s2++;
    }
    return *(const unsigned char *)s1 - *(const unsigned char *)s2;
}

int strcasecmp(const char *s1, const char *s2) {
    while (*s1 && (tolower(*s1) == tolower(*s2))) {
        s1++;
        s2++;
    }
    return tolower(*(const unsigned char *)s1) - tolower(*(const unsigned char *)s2);
}

char *strcpy(char *dst, const char *src) {
    char *r = dst;
    while ((*dst++ = *src++)) { }
    return r;
}

char *strncpy(char *dst, const char *src, size_t n) {
    char *r = dst;
    while (n && (*dst = *src)) {
        dst++;
        src++;
        n--;
    }
    while (n--)
        *dst++ = '\0';
    return r;
}

char *strcat(char *dst, const char *src) {
    char *r = dst;
    while (*dst)
        dst++;
    while ((*dst++ = *src++)) { }
    return r;
}

// Appends at most n-1 characters and always terminates, i.e. n is the size of
// the destination buffer.  This is *not* the C standard strncat, but it is the
// only sane thing to do when building paths on a machine without an MMU.
char *strncat(char *dst, const char *src, size_t n) {
    size_t i = strlen(dst);
    while (i + 1 < n && *src)
        dst[i++] = *src++;
    dst[i] = '\0';
    return dst;
}

char *strchr(const char *s, int c) {
    for (; *s; s++)
        if (*s == (char)c)
            return (char *)s;
    return (c == 0) ? (char *)s : (char *)0;
}

char *strrchr(const char *s, int c) {
    char *r = (char *)0;
    do {
        if (*s == (char)c)
            r = (char *)s;
    } while (*s++);
    return r;
}

char *strstr(const char *haystack, const char *needle) {
    if (!*needle)
        return (char *)haystack;
    for (; *haystack; haystack++) {
        const char *a = haystack;
        const char *b = needle;
        while (*b && *a == *b) {
            a++;
            b++;
        }
        if (!*b)
            return (char *)haystack;
    }
    return (char *)0;
}

char *strcasestr(const char *haystack, const char *needle) {
    if (!*needle)
        return (char *)haystack;
    for (; *haystack; haystack++) {
        const char *a = haystack;
        const char *b = needle;
        while (*b && tolower(*a) == tolower(*b)) {
            a++;
            b++;
        }
        if (!*b)
            return (char *)haystack;
    }
    return (char *)0;
}
