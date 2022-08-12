if(!(Test-Path "build")) {
    New-Item "build" -ItemType Directory
}

odin build src -out:build/chip8.exe -o:speed -disable-assert -no-bounds-check -show-timings -strict-style