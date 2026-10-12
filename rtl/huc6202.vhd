--============================================================================
--  HUC6202
--  Copyright (C) 2018 Sorgelig
--
--  This program is free software; you can redistribute it and/or modify it
--  under the terms of the GNU General Public License as published by the Free
--  Software Foundation; either version 2 of the License, or (at your option)
--  any later version.
--
--  This program is distributed in the hope that it will be useful, but WITHOUT
--  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
--  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
--  more details.
--
--  You should have received a copy of the GNU General Public License along
--  with this program; if not, write to the Free Software Foundation, Inc.,
--  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
--============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity huc6202 is
	port (
		CLK 		: in std_logic;
		CLKEN		: in std_logic;
		RESET_N	: in std_logic;
		SS_HOLD : in std_logic := '0';
		SS_LOAD : in std_logic := '0';
		SS_DATA : in std_logic_vector(63 downto 0) := (others => '0');
		SS_Q : out std_logic_vector(63 downto 0) := (others => '0');

		A			: in std_logic_vector(2 downto 0);
		WR_N		: in std_logic;
		DI			: in std_logic_vector(7 downto 0);
		DO 		: out std_logic_vector(7 downto 0);
		
		HS_F		: in std_logic;
		VDC0_IN	: in std_logic_vector(8 downto 0);
		VDC1_IN	: in std_logic_vector(8 downto 0);
		VDC_OUT	: out std_logic_vector(8 downto 0);

		SGX		: in std_logic;

		VDCNUM	: out std_logic
	);
end huc6202;

architecture rtl of huc6202 is

signal PRI0 : std_logic_vector(7 downto 0);
signal PRI1 : std_logic_vector(7 downto 0);
signal WIN1 : std_logic_vector(9 downto 0);
signal WIN2 : std_logic_vector(9 downto 0);
signal X    : std_logic_vector(9 downto 0);
signal PRIN : std_logic_vector(1 downto 0);
signal PRI  : std_logic_vector(3 downto 0);

signal VDC_PRI		: std_logic_vector(8 downto 0);
signal video_output : std_logic_vector(8 downto 0);
signal cpu_output : std_logic_vector(7 downto 0);
signal vdc_select : std_logic;

begin

VDC_OUT <= video_output;
DO <= cpu_output;
VDCNUM <= vdc_select;
SS_Q <= cpu_output & vdc_select & video_output & X & WIN2 & WIN1 & PRI1 & PRI0;

PRIN(0) <= '1' when WIN1 <= x"40" or X >= WIN1 else '0';
PRIN(1) <= '1' when WIN2 <= x"40" or X >= WIN2 else '0';
PRI <= PRI0(3 downto 0) when PRIN = "00" else
		 PRI0(7 downto 4) when PRIN = "01" else
		 PRI1(3 downto 0) when PRIN = "10" else
		 PRI1(7 downto 4);

VDC_PRI <= VDC0_IN when VDC0_IN(3 downto 0) /= "0000" else VDC1_IN;

process( CLK )
	variable VDCDATA : std_logic_vector(8 downto 0);
begin
	if rising_edge(CLK) then
		if SS_HOLD = '1' and SS_LOAD = '1' and RESET_N = '1' then
			X <= SS_DATA(45 downto 36);
			video_output <= SS_DATA(54 downto 46);
		elsif CLKEN = '1' and SS_HOLD = '0' then
			X <= X + 1;
			if HS_F = '1' then
				X <= (others => '0');
			end if;

			case PRI(1 downto 0) is
				when "00" =>
					VDCDATA := (others => '0');
				when "01" =>
					VDCDATA := VDC0_IN;
				when "10" =>
					VDCDATA := VDC1_IN;
				when others =>
					VDCDATA := VDC_PRI;
					case PRI(3 downto 2) is
						when "01" =>
							if VDC1_IN(8) = '1' and VDC0_IN(8) = '0' and VDC1_IN(3 downto 0) /= "0000" then
								VDCDATA := VDC1_IN;
							end if;
						when "10" =>
							if VDC1_IN(8) = '0' and VDC0_IN(8) = '1' and VDC1_IN(3 downto 0) /= "0000" then
								VDCDATA := VDC1_IN;
							end if;
						when others => null;
					end case;
			end case;

			video_output <= VDCDATA;
		end if;
	end if;
end process;

process( CLK ) begin
	if rising_edge(CLK) then
		if RESET_N = '0' then
			PRI0 <= "00010001";
			PRI1 <= "00010001";
			WIN1 <= (others => '0');
			WIN2 <= (others => '0');
			vdc_select <= '0';
			cpu_output <= X"FF";
		elsif SS_HOLD = '1' and SS_LOAD = '1' then
			PRI0 <= SS_DATA(7 downto 0);
			PRI1 <= SS_DATA(15 downto 8);
			WIN1 <= SS_DATA(25 downto 16);
			WIN2 <= SS_DATA(35 downto 26);
			vdc_select <= SS_DATA(55);
			cpu_output <= SS_DATA(63 downto 56);
		elsif SS_HOLD = '0' then
			if WR_N = '0' then
				case A is
					when "000" => PRI0 <= DI;
					when "001" => PRI1 <= DI;
					when "010" => WIN1(7 downto 0) <= DI;
					when "011" => WIN1(9 downto 8) <= DI(1 downto 0);
					when "100" => WIN2(7 downto 0) <= DI;
					when "101" => WIN2(9 downto 8) <= DI(1 downto 0);
					when "110" => vdc_select <= DI(0);
					when others => null;
				end case;
			end if;
			case A is
				when "000" => cpu_output <= PRI0;
				when "001" => cpu_output <= PRI1;
				when "010" => cpu_output <= WIN1(7 downto 0);
				when "011" => cpu_output <= "000000" & WIN1(9 downto 8);
				when "100" => cpu_output <= WIN2(7 downto 0);
				when "101" => cpu_output <= "000000" & WIN2(9 downto 8);
				when others => cpu_output <= X"00";
			end case;
		end if;
	end if;
end process;

end rtl;
