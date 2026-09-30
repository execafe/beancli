set quiet

default:
    just -l

test:
    zig test tests.zig

x file *args:
    zig run {{file}} -- {{args}}

c file:
    zig build-exe {{file}}

d file *args:
    zig build-exe {{file}}
    gf2 --args {{file_stem(file)}} {{args}} &
