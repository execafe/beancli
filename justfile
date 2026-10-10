set quiet

default:
    just -l

test:
    zig test tests.zig

x file *args:
    zig run {{file}} -- {{args}}

c file:
    mkdir -p zig-out/
    zig build-exe {{file}} -femit-bin=zig-out/{{file_stem(file)}}

d file *args:
    mkdir -p zig-out/
    zig build-exe {{file}} -femit-bin=zig-out/{{file_stem(file)}}
    gf2 --args zig-out/{{file_stem(file)}} {{args}} &
