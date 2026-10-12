library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

-- On the falling edge of REQ the mixer updates LDATA and RDATA, and clears the accumulators
-- LEFT_STB and RIGHT_STB must go high for a single cycle to mark incoming data.
-- SAMPLE and ATTENUATION should remain stable until the next _STB pulse.
-- There must be at least one idle cycle between _STB pulses

entity psg_mixer is
	generic (
		O_WIDTH : integer := 24;
		A_WIDTH : integer := 24;
		VOLTAB_FILE: string := "voltab_small.mif"
	);
	port (
		CLK 	: in std_logic;
		RESET_N	: in std_logic;
		SS_HOLD : in std_logic := '0';
		SS_LOAD : in std_logic := '0';
		SS_DATA : in std_logic_vector(4*A_WIDTH+2*O_WIDTH+36 downto 0) := (others => '0');
		SS_Q : out std_logic_vector(4*A_WIDTH+2*O_WIDTH+36 downto 0) := (others => '0');

		-- Incoming audio data
		REQ : in std_logic;
		SAMPLE : in std_logic_vector(4 downto 0);
		ATTENUATION : IN std_logic_vector(6 downto 0);
		LEFT_STB : in std_logic;
		RIGHT_STB : in std_logic;

		-- DAC Interface
		
		LDATA		: out std_logic_vector(O_WIDTH-1 downto 0);
		RDATA		: out std_logic_vector(O_WIDTH-1 downto 0)
	);
end psg_mixer;

architecture rtl of psg_mixer is

signal sample_in : signed(5 downto 0);
signal sample_offset : signed(5 downto 0);
signal scale : std_logic_vector(A_WIDTH-1 downto 0);
signal product : signed(A_WIDTH+5 downto 0);

signal l_acc : signed(A_WIDTH+5 downto 0);
signal r_acc : signed(A_WIDTH+5 downto 0);

signal l_pipe : std_logic_vector(3 downto 0);
signal r_pipe : std_logic_vector(3 downto 0);
signal req_pipe : std_logic_vector(4 downto 0);
signal scale_ram, scale_saved : std_logic_vector(A_WIDTH-1 downto 0);
signal scale_restored : std_logic := '0';
signal left_output, right_output : std_logic_vector(O_WIDTH-1 downto 0);

begin

LDATA <= left_output;
RDATA <= right_output;
scale <= scale_saved when scale_restored = '1' else scale_ram;
SS_Q <= scale & right_output & left_output & req_pipe & r_pipe & l_pipe &
	std_logic_vector(r_acc) & std_logic_vector(l_acc) &
	std_logic_vector(product) & std_logic_vector(sample_offset);

-- attenuation table

VT : entity work.dpram generic map (8,A_WIDTH/2,VOLTAB_FILE)
port map (
	clock		=> CLK,
	address_a=> '0'&ATTENUATION,
	address_b=> '1'&ATTENUATION,
	enable_a => not SS_HOLD,
	enable_b => not SS_HOLD,
	q_a		=> scale_ram(A_WIDTH-1 downto A_WIDTH/2),
	q_b		=> scale_ram(A_WIDTH/2-1 downto 0)
);


sample_in(5 downto 1) <= signed(sample);
sample_in(0)<='0';

-- Pipeline control

process(clk, RESET_N) begin
	if RESET_N = '0' then
		left_output<=(others=>'0');
		right_output<=(others=>'0');
		l_pipe<=(others=>'0');
		r_pipe<=(others=>'0');
		req_pipe<="10000";
		scale_restored <= '0';
	elsif rising_edge(clk) then
		if SS_HOLD = '1' and SS_LOAD = '1' then
			sample_offset <= signed(SS_DATA(5 downto 0));
			product <= signed(SS_DATA(A_WIDTH+11 downto 6));
			l_acc <= signed(SS_DATA(2*A_WIDTH+17 downto A_WIDTH+12));
			r_acc <= signed(SS_DATA(3*A_WIDTH+23 downto 2*A_WIDTH+18));
			l_pipe <= SS_DATA(3*A_WIDTH+27 downto 3*A_WIDTH+24);
			r_pipe <= SS_DATA(3*A_WIDTH+31 downto 3*A_WIDTH+28);
			req_pipe <= SS_DATA(3*A_WIDTH+36 downto 3*A_WIDTH+32);
			left_output <= SS_DATA(3*A_WIDTH+36+O_WIDTH downto 3*A_WIDTH+37);
			right_output <= SS_DATA(3*A_WIDTH+36+2*O_WIDTH downto 3*A_WIDTH+37+O_WIDTH);
			scale_saved <= SS_DATA(4*A_WIDTH+36+2*O_WIDTH downto 3*A_WIDTH+37+2*O_WIDTH);
			scale_restored <= '1';
		elsif SS_HOLD = '0' then
		scale_restored <= '0';
		l_pipe<=l_pipe(2 downto 0)&LEFT_STB;
		r_pipe<=r_pipe(2 downto 0)&RIGHT_STB;
		req_pipe<=req_pipe(3 downto 0)&REQ;

		-- latch incoming data one cycle after strobe
		if l_pipe(0)='1' or r_pipe(0)='1' then
			sample_offset<=sample_in-31;
		end if;

		-- scale shuld be valid by *pipe(1), so product should be valid by *pipe(2)
		product <= sample_offset * signed(scale);

		-- at *pipe(2) add the signal to the appropriate accumulator
		if l_pipe(2)='1' then
			l_acc<=l_acc+signed(product);
		end if;
		
		if r_pipe(2)='1' then
			r_acc<=r_acc+signed(product);
		end if;

		-- Copy accumulators to output if we're done
		if req_pipe(1)='0' then
			left_output<=std_logic_vector(l_acc(A_WIDTH+4 downto A_WIDTH+5-O_WIDTH));
			right_output<=std_logic_vector(r_acc(A_WIDTH+4 downto A_WIDTH+5-O_WIDTH));
			l_acc<=(others=>'0');
			r_acc<=(others=>'0');
		end if;
		end if;

	end if;
end process;

	
end architecture;
