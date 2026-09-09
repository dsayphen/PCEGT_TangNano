--------------------------------------------------------------------------------
-- VHDL wrapper around the Gowin IP-Core-Generator "DP" (true dual port BSRAM)
-- primitive for the (addr_width=9, data_width=10) configuration used by
-- HUC6270's SPR_LINE_BUF0/SPR_LINE_BUF1.  See dpram_ip_8x16.vhd for the full
-- rationale (WRITE_MODE0/1 = Normal / 2'b00, matching nand2mario/snestang's
-- Gowin_DPB_OAM.v, to avoid the PA2122 placement failure hit by the
-- behaviourally-inferred dpram entity on this instance).
--
-- Requires the generated gowin_dpb_line.v in the project, with its top
-- module renamed from the IP Core Generator's default "Gowin_DP" to
-- "Gowin_DP_line" to avoid a name clash with the (8,16) wrapper's own
-- generated Gowin_DP module (see gowin_dpb_sat.v / dpram_ip_8x16.vhd).
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

entity dpram_ip_9x10 is
	generic (
		disable_value : std_logic := '1'
	);
	PORT
	(
		clock			: in  STD_LOGIC;
		address_a	: in  STD_LOGIC_VECTOR (8 DOWNTO 0);
		data_a		: in  STD_LOGIC_VECTOR (9 DOWNTO 0) := (others => '0');
		enable_a		: in  STD_LOGIC := '1';
		wren_a		: in  STD_LOGIC := '0';
		q_a			: out STD_LOGIC_VECTOR (9 DOWNTO 0);
		cs_a        : in  std_logic := '1';

		address_b	: in  STD_LOGIC_VECTOR (8 DOWNTO 0) := (others => '0');
		data_b		: in  STD_LOGIC_VECTOR (9 DOWNTO 0) := (others => '0');
		enable_b		: in  STD_LOGIC := '1';
		wren_b		: in  STD_LOGIC := '0';
		q_b			: out STD_LOGIC_VECTOR (9 DOWNTO 0);
		cs_b        : in  std_logic := '1'
	);
end entity;

architecture STRUCT of dpram_ip_9x10 is

	component Gowin_DP_line is
		port (
			douta : out std_logic_vector(9 downto 0);
			doutb : out std_logic_vector(9 downto 0);
			clka  : in  std_logic;
			ocea  : in  std_logic;
			cea   : in  std_logic;
			reseta: in  std_logic;
			wrea  : in  std_logic;
			clkb  : in  std_logic;
			oceb  : in  std_logic;
			ceb   : in  std_logic;
			resetb: in  std_logic;
			wreb  : in  std_logic;
			ada   : in  std_logic_vector(8 downto 0);
			dina  : in  std_logic_vector(9 downto 0);
			adb   : in  std_logic_vector(8 downto 0);
			dinb  : in  std_logic_vector(9 downto 0)
		);
	end component;

	signal douta_i, doutb_i : std_logic_vector(9 downto 0);

begin

	q_a <= douta_i when cs_a = '1' else (others => disable_value);
	q_b <= doutb_i when cs_b = '1' else (others => disable_value);

	u_dp : Gowin_DP_line
	port map (
		douta  => douta_i,
		doutb  => doutb_i,
		clka   => clock,
		ocea   => enable_a,
		cea    => enable_a and cs_a,
		reseta => '0',
		wrea   => wren_a and cs_a,
		clkb   => clock,
		oceb   => enable_b,
		ceb    => enable_b and cs_b,
		resetb => '0',
		wreb   => wren_b and cs_b,
		ada    => address_a,
		dina   => data_a,
		adb    => address_b,
		dinb   => data_b
	);

end architecture;
