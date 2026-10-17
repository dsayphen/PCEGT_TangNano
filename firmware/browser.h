//
// SD card file browser.
//

#ifndef H_BROWSER
#define H_BROWSER

// Runs the browser until a ROM or a CD has been started.
void browse(void);

// Starts the browser in the active core's game folder when it exists.
void browser_default_dir(void);

#endif
