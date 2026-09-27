//
// CD-ROM emulation: CUE parsing, System Card loading, SCSI command service
// and CD-DA streaming.
//

#ifndef H_CD
#define H_CD

#include <stdint.h>
#include <stddef.h>

extern int      cd_active;
extern int      cd_audio_playing;
extern uint32_t cd_audio_bytes_fed;
extern uint32_t cd_audio_read_ms;
extern uint32_t cd_audio_feed_ms;

int  is_cd_dir(const char *name);
int  find_cd_cue(char *cue_name, size_t cue_len);
int  open_cd_image(const char *cue_name);
void cd_service(void);
// Stops CD-DA playback and rewinds, used when the game is reset.
void cd_audio_reset(void);
// Closes the data track image if a CD is active.
void cd_close(void);

#endif
