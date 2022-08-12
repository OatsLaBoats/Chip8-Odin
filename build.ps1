if(!(Test-Path "build")) {
    New-Item "build" -ItemType Directory
}

odin run src -out:build/chip8.exe -o:minimal -show-timings -debug -strict-style -- '.\Breakout [Carmelo Cortez, 1979].ch8'