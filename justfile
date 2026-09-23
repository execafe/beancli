set quiet

default:
    just -l

test:
    zig test tests.zig


x file *args:
    zig run {{file}} -- {{args}}
