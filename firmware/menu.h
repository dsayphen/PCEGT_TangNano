//
// In-game menus: pause menu, video / audio sub-menus and the Select+D-pad
// zoom / scanline shortcuts.
//

#ifndef H_MENU
#define H_MENU

void zoom_cycle(void);
void scanline_cycle(int dir);
void vdc_timing_dump(void);
int  pause_menu(void);
void options_menu(void);

#endif
