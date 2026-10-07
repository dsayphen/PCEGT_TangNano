/*-----------------------------------------------------------------------*/
/* Low level disk I/O glue for FatFs on the Tang Nano 20K PC Engine port  */
/*                                                                       */
/* Read-only: the card is never written, so disk_write is compiled out by */
/* FF_FS_READONLY in ffconf.h.                                           */
/*                                                                       */
/* Based on the SNESTang diskio.c (nand2mario, GPLv3), which is itself    */
/* the FatFs skeleton by ChaN.                                           */
/*-----------------------------------------------------------------------*/

#include "ff.h"
#include "diskio.h"
#include "../picorv32.h"

#define DEV_SD 0

int sd_initialized = 0;
volatile int sd_trace_enabled = 0;
static int sd_trace_was_enabled;
static unsigned sd_trace_reads_left;
int sd_writesector(uint32_t start_block, const uint8_t *buffer, uint32_t sector_count);

DSTATUS disk_status (BYTE pdrv)
{
    if (pdrv != DEV_SD)
        return STA_NOINIT;
    return sd_initialized ? 0 : STA_NOINIT;
}

DSTATUS disk_initialize (BYTE pdrv)
{
    if (pdrv != DEV_SD)
        return STA_NOINIT;

    if (sd_init() == 0) {
        sd_initialized = 1;
        return 0;
    }

    sd_initialized = 0;
    return STA_NOINIT;
}

DRESULT disk_read (BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    int ok;
    int trace_read = 0;

    if (sd_trace_enabled && !sd_trace_was_enabled)
        sd_trace_reads_left = 12;
    sd_trace_was_enabled = sd_trace_enabled;

    if (pdrv != DEV_SD)
        return RES_PARERR;
    if (!sd_initialized)
        return RES_NOTRDY;

    if (sd_trace_enabled && sd_trace_reads_left != 0) {
        uart_printf("sd: read begin sector=%d count=%d\n", (int)sector, (int)count);
        sd_trace_reads_left--;
        trace_read = 1;
    }
    ok = sd_readsector((uint32_t)sector, (uint8_t *)buff, count);
    if (sd_trace_enabled && trace_read)
        uart_printf("sd: read end result=%d\n", ok);
    else if (sd_trace_enabled && !ok)
        uart_printf("sd: read fail sector=%d count=%d\n", (int)sector, (int)count);
    return ok ? RES_OK : RES_ERROR;
}

#if FF_FS_READONLY == 0 || defined(_FS_READONLY)
DRESULT disk_write (BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv != DEV_SD)
        return RES_PARERR;
    if (!sd_initialized)
        return RES_NOTRDY;

    // Utilise sd_writesector (ou une boucle sd_writesector selon l'API de votre spi_sd.c)
    return sd_writesector((uint32_t)sector, (const uint8_t *)buff, count) ? RES_OK : RES_ERROR;
}
#endif

DRESULT disk_ioctl (BYTE pdrv, BYTE cmd, void *buff)
{
    if (pdrv != DEV_SD)
        return RES_PARERR;

    switch (cmd) {
    case CTRL_SYNC:
        return RES_OK;
    case GET_SECTOR_SIZE:
        *(WORD *)buff = 512;
        return RES_OK;
    case GET_BLOCK_SIZE:
        *(DWORD *)buff = 1;
        return RES_OK;
    default:
        return RES_PARERR;
    }
}
