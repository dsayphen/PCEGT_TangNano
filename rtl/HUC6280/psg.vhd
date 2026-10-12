library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity psg is
	generic (
		O_WIDTH : integer := 24;
		VOLTAB_FILE: string := "HUC6280/voltab.mif"
	);
	port (
		CLK 	: in std_logic;
		CLKEN	: in std_logic;
		RESET_N	: in std_logic;
		SS_HOLD : in std_logic := '0';
		SS_LOAD : in std_logic := '0';
		SS_DATA : in std_logic_vector(2116+2*O_WIDTH downto 0) := (others => '0');
		SS_Q : out std_logic_vector(2116+2*O_WIDTH downto 0) := (others => '0');

		-- CPU Interface
		DI		: in std_logic_vector(7 downto 0);
		A 		: in std_logic_vector(3 downto 0);
		WE		: in std_logic;

		-- DAC Interface
		DAC_LATCH	: in std_logic;
		LDATA		: out std_logic_vector(O_WIDTH-1 downto 0);
		RDATA		: out std_logic_vector(O_WIDTH-1 downto 0)
	);
end psg;

architecture rtl of psg is

-- R0 - Channel Selection
signal CHSEL	: integer range 0 to 7;
-- R1 - Main Volume Adjustement
signal LMAL		: std_logic_vector(3 downto 0);
signal RMAL		: std_logic_vector(3 downto 0);

-- R2-R7 - Channel specific registers
type wavedata_t is array(0 to 31) of std_logic_vector(4 downto 0);
type chan_t is
	record
		-- Registers
		FREQ		: std_logic_vector(11 downto 0);
		DDA		: std_logic;
		CHON		: std_logic;
		AL			: std_logic_vector(4 downto 0);
		LAL		: std_logic_vector(3 downto 0);
		RAL		: std_logic_vector(3 downto 0);

		NG_FREQ	: std_logic_vector(4 downto 0);
		NE			: std_logic;

		-- Waveform generator
		WF_DATA	: wavedata_t;
		WF_ADDR	: std_logic_vector(4 downto 0);
		WF_CNT	: std_logic_vector(12 downto 0);

		WF_RES	: std_logic;
		WF_INC	: std_logic;

		-- Noise generator
		LFSR		: std_logic_vector(17 downto 0);
		NG_CNT	: std_logic_vector(11 downto 0);

		-- Outputs
		DA_OUT	: std_logic_vector(4 downto 0);
		WF_OUT	: std_logic_vector(4 downto 0);
		NG_OUT	: std_logic_vector(4 downto 0);
		-- Global output
		GL_OUT	: std_logic_vector(4 downto 0);

		-- LFO
		LFO_FREQ	: std_logic_vector(7 downto 0);
		LFCTL		: std_logic_vector(1 downto 0);
		LFTRG		: std_logic;
		LFO_CNT	: std_logic_vector(7 downto 0);
		LFO_ADD 	: std_logic_vector(11 downto 0);
	end record;
type chanarray_t is array(0 to 5) of chan_t;
signal CH		: chanarray_t;

-- Channels mixing

type mix_t is ( MIX_WAIT, MIX_NEXT, MIX_LREAD, MIX_LNEXT, MIX_RREAD, MIX_RNEXT, MIX_END );
signal MIX		: mix_t;
signal MIX_CNT	: std_logic_vector(2 downto 0);

signal mix_req : std_logic;
signal mix_sample : std_logic_vector(4 downto 0);
signal mix_atn : std_logic_vector(6 downto 0);
signal mix_l_stb : std_logic;
signal mix_r_stb : std_logic;
signal mixer_state : std_logic_vector(132+2*O_WIDTH downto 0);

begin

SS_Q(2116+2*O_WIDTH downto 1984) <= mixer_state;
SS_Q(1983 downto 1920) <= (63 downto 32 => '0') & mix_r_stb & mix_l_stb &
	mix_atn & mix_sample & mix_req & MIX_CNT &
	std_logic_vector(to_unsigned(mix_t'pos(MIX), 3)) & RMAL & LMAL &
	std_logic_vector(to_unsigned(CHSEL, 3));
state_channels : for channel in 0 to 5 generate
	SS_Q(channel*320+319 downto channel*320+294) <= (others => '0');
	SS_Q(channel*320+133 downto channel*320) <=
		CH(channel).LFO_ADD & CH(channel).LFO_CNT & CH(channel).LFTRG &
		CH(channel).LFCTL & CH(channel).LFO_FREQ & CH(channel).GL_OUT &
		CH(channel).NG_OUT & CH(channel).WF_OUT & CH(channel).DA_OUT &
		CH(channel).NG_CNT & CH(channel).LFSR & CH(channel).WF_INC &
		CH(channel).WF_RES & CH(channel).WF_CNT & CH(channel).WF_ADDR &
		CH(channel).NE & CH(channel).NG_FREQ & CH(channel).RAL & CH(channel).LAL &
		CH(channel).AL & CH(channel).CHON & CH(channel).DDA & CH(channel).FREQ;
	state_wave : for sample_index in 0 to 31 generate
		SS_Q(channel*320+138+sample_index*5 downto channel*320+134+sample_index*5)
			<= CH(channel).WF_DATA(sample_index);
	end generate;
end generate;

-- CPU Interface
process( CLK )
	variable DATA: std_logic_vector(4 downto 0);
begin
	if rising_edge( CLK ) and (SS_HOLD = '0' or RESET_N = '0' or SS_LOAD = '1') then

		for i in 0 to 5 loop
			CH(i).WF_RES <= '0';
			CH(i).WF_INC <= '0';
		end loop;

		if RESET_N = '0' then

			CHSEL <= 0;
			LMAL <= (others => '0');
			RMAL <= (others => '0');

			for i in 0 to 5 loop
				CH(i).FREQ <= (others => '0');
				CH(i).DDA <= '0';
				CH(i).CHON <= '0';
				CH(i).LAL <= (others => '0');
				CH(i).RAL <= (others => '0');
				CH(i).NG_FREQ <= (others => '0');
				CH(i).NE <= '0';
				CH(i).DA_OUT <= (others => '0');
				CH(i).LFO_FREQ <= (others => '0');
				CH(i).LFCTL <= "00";
				CH(i).LFTRG <= '0';
			end loop;
		elsif SS_HOLD = '1' and SS_LOAD = '1' then
			CHSEL <= to_integer(unsigned(SS_DATA(1922 downto 1920)));
			LMAL <= SS_DATA(1926 downto 1923);
			RMAL <= SS_DATA(1930 downto 1927);
			for channel in 0 to 5 loop
				CH(channel).FREQ <= SS_DATA(channel*320+11 downto channel*320);
				CH(channel).DDA <= SS_DATA(channel*320+12);
				CH(channel).CHON <= SS_DATA(channel*320+13);
				CH(channel).AL <= SS_DATA(channel*320+18 downto channel*320+14);
				CH(channel).LAL <= SS_DATA(channel*320+22 downto channel*320+19);
				CH(channel).RAL <= SS_DATA(channel*320+26 downto channel*320+23);
				CH(channel).NG_FREQ <= SS_DATA(channel*320+31 downto channel*320+27);
				CH(channel).NE <= SS_DATA(channel*320+32);
				CH(channel).WF_RES <= SS_DATA(channel*320+51);
				CH(channel).WF_INC <= SS_DATA(channel*320+52);
				CH(channel).DA_OUT <= SS_DATA(channel*320+87 downto channel*320+83);
				CH(channel).LFO_FREQ <= SS_DATA(channel*320+110 downto channel*320+103);
				CH(channel).LFCTL <= SS_DATA(channel*320+112 downto channel*320+111);
				CH(channel).LFTRG <= SS_DATA(channel*320+113);
				for sample_index in 0 to 31 loop
					CH(channel).WF_DATA(sample_index) <= SS_DATA(channel*320+138+sample_index*5 downto channel*320+134+sample_index*5);
				end loop;
			end loop;
		else
			if WE = '1' then
				case A is
				when "0000" =>
					CHSEL <= conv_integer(DI(2 downto 0));

				when "0001" =>
					LMAL <= DI(7 downto 4);
					RMAL <= DI(3 downto 0);

				when "0010" =>
					CH(CHSEL).FREQ(7 downto 0) <= DI;

				when "0011" =>
					CH(CHSEL).FREQ(11 downto 8) <= DI(3 downto 0);

				when "0100" =>
					CH(CHSEL).CHON <= DI(7);
					CH(CHSEL).DDA <= DI(6);
					CH(CHSEL).AL <= DI(4 downto 0);
					if CH(CHSEL).DDA = '1' and DI(6) = '0' then
						CH(CHSEL).WF_RES <= '1';
					end if;

				when "0101" =>
					CH(CHSEL).LAL <= DI(7 downto 4);
					CH(CHSEL).RAL <= DI(3 downto 0);

				when "0110" =>
					if CH(CHSEL).DDA = '0' then
						CH(CHSEL).WF_DATA(conv_integer(CH(CHSEL).WF_ADDR)) <= DI(4 downto 0);
					end if;
					if CH(CHSEL).CHON = '1' then
						CH(CHSEL).DA_OUT <= DI(4 downto 0);
					end if;
					if CH(CHSEL).DDA = '0' and CH(CHSEL).CHON = '0' then
						CH(CHSEL).WF_INC <= '1';
					end if;

				when "0111" =>
					if CHSEL = 4 or CHSEL =5 then
						CH(CHSEL).NE <= DI(7);
						CH(CHSEL).NG_FREQ <= DI(4 downto 0);
					end if;

				when "1000" =>
					CH(1).LFO_FREQ <= DI;

				when "1001" =>
					CH(1).LFCTL <= DI(1 downto 0);
					CH(1).LFTRG <= DI(7);

				when others => null;
				end case;
			end if;
		end if;
		for i in 0 to 5 loop
			if RESET_N = '0' then
				CH(i).GL_OUT <= (others => '0');
				CH(i).WF_CNT <= (others => '0');
				CH(i).LFSR <= (others => '0');
				CH(i).NG_CNT <= (others => '0');
				CH(i).LFO_CNT <= (others => '0');
			elsif SS_HOLD = '1' and SS_LOAD = '1' then
				CH(i).WF_ADDR <= SS_DATA(i*320+37 downto i*320+33);
				CH(i).WF_CNT <= SS_DATA(i*320+50 downto i*320+38);
				CH(i).LFSR <= SS_DATA(i*320+70 downto i*320+53);
				CH(i).NG_CNT <= SS_DATA(i*320+82 downto i*320+71);
				CH(i).WF_OUT <= SS_DATA(i*320+92 downto i*320+88);
				CH(i).NG_OUT <= SS_DATA(i*320+97 downto i*320+93);
				CH(i).GL_OUT <= SS_DATA(i*320+102 downto i*320+98);
				CH(i).LFO_CNT <= SS_DATA(i*320+121 downto i*320+114);
			else
				if CH(i).WF_RES = '1' then
					CH(i).WF_ADDR <= (others => '0');
				end if;
				if CH(i).WF_INC = '1' then
					CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
				end if;

				if CH(i).LFCTL /= "00" then
					CH(i).WF_OUT <= CH(i).WF_DATA(conv_integer(CH(i).WF_ADDR));

					if CH(i).LFTRG = '1' then
						CH(i).WF_ADDR <= (others => '0');
						CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
						CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
					else
						if CLKEN = '1' then
							CH(i).LFO_CNT <= CH(i).LFO_CNT - 1;
							if CH(i).LFO_CNT = 0 then
								CH(i).LFO_CNT <= CH(i).LFO_FREQ - 1;
								CH(i).WF_CNT <= CH(i).WF_CNT - 1;
								if CH(i).WF_CNT = 0 then
									CH(i).WF_CNT <= (CH(i).FREQ - 1) & "1";
									CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
								end if;
							end if;
						end if;
					end if;
				elsif CH(i).CHON = '0' then
					CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
				elsif CH(i).DDA = '0' then
					CH(i).WF_OUT <= CH(i).WF_DATA(conv_integer(CH(i).WF_ADDR));

					if CLKEN = '1' then
						CH(i).WF_CNT <= CH(i).WF_CNT - 1;
						if CH(i).WF_CNT = 0 then
							CH(i).WF_CNT <= (CH(i).FREQ - 1 + CH(i).LFO_ADD) & "1";
							CH(i).WF_ADDR <= CH(i).WF_ADDR + 1;
						end if;
					end if;
				end if;

				if CH(i).NE = '0' then
				if CH(i).NG_FREQ = "11111" then
						CH(i).NG_CNT <= "000000111111";
					else
						CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
					end if;
				else
					if CH(i).LFSR(0) = '0' then
						CH(i).NG_OUT <= "00000";
					else
						CH(i).NG_OUT <= "11111";
					end if;

					if CLKEN = '1' then
						CH(i).NG_CNT <= CH(i).NG_CNT - 1;
						if CH(i).NG_CNT = 0 then
							if CH(i).NG_FREQ = "11111" then
								CH(i).NG_CNT <= "000000111111";
							else
								CH(i).NG_CNT <= ( not(CH(i).NG_FREQ) - 1) & "1111111";
							end if;
							if CH(i).LFSR = 0 then
								CH(i).LFSR(0) <= '1';
							else
								CH(i).LFSR <= (CH(i).LFSR(0) xor CH(i).LFSR(1) xor CH(i).LFSR(11) xor CH(i).LFSR(12) xor CH(i).LFSR(17)) & CH(i).LFSR(17 downto 1);
							end if;
						end if;
					end if;
				end if;

				if CH(i).CHON = '0' then
					CH(i).GL_OUT <= "10000";		-- Not zero; this should be midpoint in the range to reduce 'pop' sound
				elsif CH(i).DDA = '1' then
					CH(i).GL_OUT <= CH(i).DA_OUT;
				elsif CH(i).NE = '1' then
					CH(i).GL_OUT <= CH(i).NG_OUT;
				else
					CH(i).GL_OUT <= CH(i).WF_OUT;
				end if;
			end if;
		end loop;
		if RESET_N = '0' then
			for i in 0 to 5 loop
				CH(i).LFO_ADD <= (others => '0');
			end loop;
		elsif SS_HOLD = '1' and SS_LOAD = '1' then
			for channel in 0 to 5 loop
				CH(channel).LFO_ADD <= SS_DATA(channel*320+133 downto channel*320+122);
			end loop;
		else
			DATA := CH(1).WF_DATA(conv_integer(CH(1).WF_ADDR)) xor "10000";
			CH(0).LFO_ADD(11 downto 8) <= DATA(4) & DATA(4) & DATA(4) & DATA(4);
			case CH(1).LFCTL is
			when "01" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA(4) & DATA(4) & DATA;
			when "10" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(4) & DATA & "00";
			when "11" =>   CH(0).LFO_ADD(7 downto 0) <= DATA(3 downto 0) & "0000";
			when others => CH(0).LFO_ADD <= (others => '0');
			end case;
		end if;
		if RESET_N = '0' then
			mix_req<='0';
			mix_l_stb<='0';
			mix_r_stb<='0';
			MIX <= MIX_WAIT;
		elsif SS_HOLD = '1' and SS_LOAD = '1' then
			MIX <= mix_t'val(to_integer(unsigned(SS_DATA(1933 downto 1931))));
			MIX_CNT <= SS_DATA(1936 downto 1934);
			mix_req <= SS_DATA(1937);
			mix_sample <= SS_DATA(1942 downto 1938);
			mix_atn <= SS_DATA(1949 downto 1943);
			mix_l_stb <= SS_DATA(1950);
			mix_r_stb <= SS_DATA(1951);
		else
			mix_sample<=CH(conv_integer(MIX_CNT)).GL_OUT;
			mix_l_stb<='0';
			mix_r_stb<='0';

			case MIX is
			when MIX_WAIT =>
				MIX_CNT <= (others => '0');
				if DAC_LATCH = '1' then
					mix_req<='1';
					MIX <= MIX_NEXT;
				end if;

			when MIX_NEXT =>
				mix_atn<=( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).LAL & "1") - (LMAL & "1") );
				mix_l_stb<=CH(conv_integer(MIX_CNT)).CHON;
				MIX <= MIX_LREAD;

			when MIX_LREAD =>
				MIX <= MIX_LNEXT;

			when MIX_LNEXT =>
				mix_atn<=( "1011101" - CH(conv_integer(MIX_CNT)).AL - (CH(conv_integer(MIX_CNT)).RAL & "1") - (RMAL & "1") );
				mix_r_stb<=CH(conv_integer(MIX_CNT)).CHON;
				MIX <= MIX_RREAD;

			when MIX_RREAD =>
				MIX <= MIX_RNEXT;

			when MIX_RNEXT =>
				if MIX_CNT = "101" then
					MIX <= MIX_END;
				else
					MIX_CNT <= MIX_CNT + 1;
					MIX <= MIX_NEXT;
				end if;

			when MIX_END =>
				mix_req<='0';
				MIX <= MIX_WAIT;

			when others => null;
			end case;
		end if;
	end if;
end process;


-- Multiplier-based channel mixing
psgmix : entity work.psg_mixer
generic map (
	O_WIDTH => O_WIDTH,
	VOLTAB_FILE => VOLTAB_FILE
)
port map (
	CLK		=> CLK,
	RESET_N => RESET_N,
	SS_HOLD => SS_HOLD,
	SS_LOAD => SS_LOAD,
	SS_DATA => SS_DATA(2116+2*O_WIDTH downto 1984),
	SS_Q => mixer_state,
		REQ => mix_req,
	SAMPLE => mix_sample,
	ATTENUATION => mix_atn,
	LEFT_STB => mix_l_stb,
	RIGHT_STB => mix_r_stb,

	LDATA => LDATA,
	RDATA => RDATA
);

end rtl;

