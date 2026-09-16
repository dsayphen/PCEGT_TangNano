--------------------------------------------------------------------------------
-- HuCard-only wrapper around pce_top (extram variant) for the Tang Nano 20K.
--
-- Purpose:
--   * enable the SuperGrafx second VDC while keeping Game Genie disabled;
--     CD_SUPPORT = 0 / AC_SUPPORT = 0
--     so neither the CD-ROM unit nor the Arcade Card are built, and
--     USE_INTERNAL_RAM = 1 so the 8 KiB work RAM is a block RAM)
--   * tie off every interface that this build does not use
--   * expose both VDC video RAM ports to the interleaved SDRAM controller
--   * expose a small, all-lowercase port list to the Verilog top level
--
-- Only the HuCard ROM remains as an external memory client, which is what
-- rtl/tang/pce_sdram_ctrl.v serves from the on-package SDRAM.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity pce_core is
    generic (
        -- 0 = HuCard standard (un seul VDC, fonctionnel sur ce device)
		-- 1 = SuperGrafx (second VDC + VRAM doublée)
        SGX_SUPPORT : integer := 1
	);

	port (
		clk        : in  std_logic;
		reset      : in  std_logic;
		cold_reset : in  std_logic;

		-- HuCard ROM (external, SDRAM)
		rom_rd     : out std_logic;
		rom_rdy    : in  std_logic;
		rom_a      : out std_logic_vector(21 downto 0);
		rom_do     : in  std_logic_vector(7 downto 0);
		rom_sz     : in  std_logic_vector(7 downto 0);
		sgx_mode   : in  std_logic;
		pause      : in  std_logic := '0';   -- '1' freezes the HuC6280 (WAIT_N); video keeps scanning out
		cheat_enable : in std_logic := '0';
		cheat_code : in std_logic_vector(127 downto 0) := (others => '0');
		cheat_load : in std_logic := '0';
		cheat_reset : in std_logic := '0';

		-- VDC0 video RAM (external SDRAM)
		vram0_a    : out std_logic_vector(15 downto 0);
		vram0_do   : out std_logic_vector(15 downto 0);
		vram0_di   : in  std_logic_vector(15 downto 0);
		vram0_rd   : out std_logic;
		vram0_we   : out std_logic;

		-- VDC1 video RAM (external SDRAM, SuperGrafx)
		vram1_a    : out std_logic_vector(15 downto 0);
		vram1_do   : out std_logic_vector(15 downto 0);
		vram1_di   : in  std_logic_vector(15 downto 0);
		vram1_rd   : out std_logic;
		vram1_we   : out std_logic;

		-- pad
		joy_out    : out std_logic_vector(1 downto 0);
		joy_in     : in  std_logic_vector(3 downto 0);

		-- audio (signed)
		aud_l      : out std_logic_vector(19 downto 0);
		aud_r      : out std_logic_vector(19 downto 0);

		-- video
		vid_ce     : out std_logic;
		vid_r      : out std_logic_vector(2 downto 0);
		vid_g      : out std_logic_vector(2 downto 0);
		vid_b      : out std_logic_vector(2 downto 0);
		vid_hs     : out std_logic;
		vid_vs     : out std_logic;
		vid_hbl    : out std_logic;
		vid_vbl    : out std_logic;
		vid_dcc    : out std_logic_vector(1 downto 0)
	);
end pce_core;

architecture rtl of pce_core is

    signal sgx_i    : std_logic;

	signal gg_code_i : std_logic_vector(128 downto 0);
	signal ff_byte   : std_logic_vector(7 downto 0) := x"FF";
	signal zero_byte : std_logic_vector(7 downto 0) := x"00";
	signal zero_nib  : std_logic_vector(3 downto 0) := x"0";

	signal psg_l : signed(19 downto 0);
	signal psg_r : signed(19 downto 0);

	-- unused CD / Arcade Card / Game Genie outputs
	signal cdda_l_nc : signed(19 downto 0);
	signal cdda_r_nc : signed(19 downto 0);
	signal adpcm_nc  : signed(15 downto 0);

begin

    sgx_i <= sgx_mode when SGX_SUPPORT /= 0 else '0';

	CORE : entity work.pce_top
	generic map (
		SGX_SUPPORT      => SGX_SUPPORT,
		LITE             => 0,
		PSG_O_WIDTH      => 20,
		MAX_SPRITES      => 16,
		USE_INTERNAL_RAM => 1,
		CD_SUPPORT       => 0,
		AC_SUPPORT       => 0
	)
	port map (
		RESET       => reset,
		COLD_RESET  => cold_reset,
		CLK         => clk,

		ROM_RD      => rom_rd,
		ROM_RDY     => rom_rdy,
		ROM_A       => rom_a,
		ROM_DO      => rom_do,
		ROM_SZ      => rom_sz,
		ROM_POP     => '0',
		ROM_CLKEN   => open,

		BRM_A       => open,
		BRM_DI      => open,
		BRM_DO      => ff_byte,
		BRM_WE      => open,

		VRAM0_A     => vram0_a,
		VRAM0_DO    => vram0_do,
		VRAM0_RD    => vram0_rd,
		VRAM0_WE    => vram0_we,
		VRAM0_DI    => vram0_di,

        VRAM1_A     => vram1_a,
        VRAM1_DO    => vram1_do,
        VRAM1_RD    => vram1_rd,
        VRAM1_WE    => vram1_we,
        VRAM1_DI    => vram1_di,

		GG_EN       => not cheat_enable,
		GG_CODE     => gg_code_i,
		GG_RESET    => cheat_reset,
		GG_AVAIL    => open,

		SP64        => '0',
		SGX         => sgx_i,

		JOY_OUT     => joy_out,
		JOY_IN      => joy_in,

		CD_EN       => '0',
		EXT_RAM_A   => open,
		EXT_RAM_DO  => open,
		EXT_RAM_DI  => ff_byte,
		EXT_RAM_CE  => open,
		EXT_RAM_RD  => open,
		EXT_RAM_WR  => open,
		AC_EN       => '0',

		ADRAM_A     => open,
		ADRAM_DI    => open,
		ADRAM_DO    => zero_nib,
		ADRAM_WE    => open,
		ADRAM_RD    => open,

		CD_STAT     => zero_byte,
		CD_MSG      => zero_byte,
		CD_STAT_GET => '0',

		CD_COMM     => open,
		CD_COMM_SEND=> open,

		CD_DOUT_REQ => '0',
		CD_DOUT     => open,
		CD_DOUT_SEND=> open,

		CD_REGION   => '0',
		CD_RESET    => open,

		CD_DATA     => zero_byte,
		CD_WR       => '0',
		CD_DATA_END => open,
		CD_DM       => '0',
		CD_FIFO_HALFFULL => open,

		CDDA_SL     => cdda_l_nc,
		CDDA_SR     => cdda_r_nc,
		ADPCM_S     => adpcm_nc,
		PSG_SL      => psg_l,
		PSG_SR      => psg_r,

		BG_EN       => '1',
		SPR_EN      => '1',
		GRID_EN     => "00",
		CPU_PAUSE_EN=> pause,

		BORDER_EN   => '0',
		ReducedVBL  => '1',
		VIDEO_DCC   => vid_dcc,
		VIDEO_R     => vid_r,
		VIDEO_G     => vid_g,
		VIDEO_B     => vid_b,
		VIDEO_BW    => open,
		VIDEO_CE    => vid_ce,
		VIDEO_CE_FS => open,
		VIDEO_VS    => vid_vs,
		VIDEO_HS    => vid_hs,
		VIDEO_HBL   => vid_hbl,
		VIDEO_VBL   => vid_vbl
	);

	gg_code_i <= cheat_load & cheat_code;

	aud_l <= std_logic_vector(psg_l);
	aud_r <= std_logic_vector(psg_r);

end rtl;
