library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity CDDA_FIFO is
    port (
        clock : in  std_logic;
        clear : in  std_logic;
        data  : in  std_logic_vector(31 downto 0);
        rdreq : in  std_logic;
        wrreq : in  std_logic;
        empty : out std_logic;
        full  : out std_logic;
        q     : out std_logic_vector(31 downto 0);
        usedw : out std_logic_vector(12 downto 0)
    );
end CDDA_FIFO;

architecture rtl of CDDA_FIFO is
    type mem_t is array (0 to 1535) of std_logic_vector(31 downto 0);
    signal mem : mem_t;
    signal rd_ptr : unsigned(10 downto 0) := (others => '0');
    signal wr_ptr : unsigned(10 downto 0) := (others => '0');
    signal count  : unsigned(10 downto 0) := (others => '0');
begin
    process(clock)
        variable do_read  : boolean;
        variable do_write : boolean;
    begin
        if rising_edge(clock) then
            if clear = '1' then
                rd_ptr <= (others => '0');
                wr_ptr <= (others => '0');
                count <= (others => '0');
            else
                do_read := (rdreq = '1' and count /= 0);
                do_write := (wrreq = '1' and count /= 1536);

                if do_write then
                    mem(to_integer(wr_ptr)) <= data;
                    wr_ptr <= (others => '0') when wr_ptr = 1535 else wr_ptr + 1;
                end if;
                if do_read then
                    rd_ptr <= (others => '0') when rd_ptr = 1535 else rd_ptr + 1;
                end if;

                if do_write and not do_read then
                    count <= count + 1;
                elsif do_read and not do_write then
                    count <= count - 1;
                end if;
            end if;
        end if;
    end process;

    q <= mem(to_integer(rd_ptr));
    empty <= '1' when count = 0 else '0';
    full  <= '1' when count = 1536 else '0';
    usedw <= std_logic_vector(count & "00");
end rtl;
