//
// OSD layout (32 x 20 characters) and small drawing helpers.
//

#ifndef H_OSD
#define H_OSD

#define ROW_TITLE   0
#define ROW_PATH    1
#define ROW_FIRST   3
#define PAGESIZE    16
#define ROW_STATUS  19

void status(const char *msg);
void title(void);
void print_field(int x, int y, const char *s, int w);
void message(const char *l1, const char *l2);

#endif
