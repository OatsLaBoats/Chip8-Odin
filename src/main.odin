package main

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:os"
import "core:math/rand"

import "vendor:raylib"

Chip8 :: struct {
    // Devices
    memory: []byte,
    display: Display,
    pad: Keypad,

    // Registers
    pc: int,
    i: u16,
    reg: [16]u8,

    stack: [64]u16,
    sp: int, // Stack pointer

    // Timers
    delay_timer: u8,
    sound_timer: u8,

    // Resources
    beep: raylib.Music,

    // Other
    remaining_instructions: f32,
}

Keypad :: struct {
    key: [16]bool,
}

Display :: struct {
    width: int,
    height: int,

    fb_width: int,
    fb_height: int,

    frame_buffer: []bool,
}

FONT_ADDRESS :: 0x0
PROGRAM_ADDRESS :: 0x200

main :: proc() {
    rom := parse_args()

    memory, ok1 := make([]byte, mem.Kilobyte * 4)
    if ok1 != mem.Allocator_Error.None {
        fmt.println("Failed to allocate memory")
        os.exit(-1)
    }
    defer delete(memory)

    display := Display {
        width = 512,
        height = 256,
        fb_width = 64,
        fb_height = 32,
    }

    frame_buffer, ok2 := make([]bool, display.fb_width * display.fb_height)
    if ok2 != mem.Allocator_Error.None {
        fmt.println("Failed to allocate memory")
        os.exit(-1)
    }
    defer delete(frame_buffer)

    display.frame_buffer = frame_buffer

    chip := Chip8 {
        memory = memory,
        display = display,
        pc = PROGRAM_ADDRESS,
    }

    // Load program into memory
    file_contents, file_error := os.read_entire_file_from_filename(os.args[1])
    if !file_error {
        fmt.println("Failed to read program file")
        os.exit(-1)
    }
    defer delete(file_contents)

    copy(chip.memory[PROGRAM_ADDRESS:], file_contents)

    fmt.println("\nLoaded program ", os.args[1], " into memory: \n")
    print_memory(file_contents, 40)

    font := []byte {
        0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
        0x20, 0x60, 0x20, 0x20, 0x70, // 1
        0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
        0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
        0x90, 0x90, 0xF0, 0x10, 0x10, // 4
        0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
        0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
        0xF0, 0x10, 0x20, 0x40, 0x40, // 7
        0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
        0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
        0xF0, 0x90, 0xF0, 0x90, 0x90, // A
        0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
        0xF0, 0x80, 0x80, 0x80, 0xF0, // C
        0xE0, 0x90, 0x90, 0x90, 0xE0, // D
        0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
        0xF0, 0x80, 0xF0, 0x80, 0x80, // F
    }

    // Copy the font to the begining of memory
    copy_slice(chip.memory[FONT_ADDRESS:], font)
    fmt.printf("Font data placed on address 0x0-0x%X\n", len(font))

    fmt.println("\nMemory snapshot:\n")
    print_memory(chip.memory, 40)
    fmt.println()

    flags := raylib.ConfigFlags {
        raylib.ConfigFlag.WINDOW_RESIZABLE,
    }

    raylib.SetTraceLogLevel(raylib.TraceLogLevel.NONE)
    raylib.SetConfigFlags(flags)
    raylib.SetTargetFPS(60)

    // Window creation
    raylib.InitWindow(i32(chip.display.width), i32(chip.display.height), "Chip-8")
    defer raylib.CloseWindow()
    
    // Audio initialization
    raylib.InitAudioDevice()

    chip.beep = raylib.LoadMusicStream("resources/beep.ogg")
    defer raylib.UnloadMusicStream(chip.beep)

    for !raylib.WindowShouldClose() {
        update(&chip)
        render(&chip)
    }
}

parse_args :: proc() -> string {
    if len(os.args) == 2 {
        return os.args[1]
    }
    
    fmt.println("chip8 \"rom name\"")
    os.exit(0)
}

print_memory :: proc(memory: []byte, cols: int) {
    col_count := -1
    row := 0

    fmt.print("         ")
    for i in 0..<cols {
        fmt.printf("%2d ", i)
    }

    fmt.println()
    fmt.println()

    fmt.printf("0x%4X   ", row)
    for b in memory {
        col_count += 1

        if col_count == cols {
            col_count = 0
            row += 1
            fmt.printf("\n0x%4X   ", row * cols)
        }

        fmt.printf("%2X ", b)
    }
    fmt.println()
}

update :: proc(chip: ^Chip8) {
    update_keypad(&chip.pad)

    if raylib.IsWindowResized() {
        chip.display.width = int(raylib.GetScreenWidth())
        chip.display.height = int(raylib.GetScreenHeight())
    }

    raylib.UpdateMusicStream(chip.beep)

    // Update timers
    if chip.delay_timer > 0 do chip.delay_timer -= 1
    if chip.sound_timer > 0 do chip.sound_timer -= 1
    
    if chip.sound_timer != 0 && !raylib.IsMusicStreamPlaying(chip.beep) {
        raylib.PlayMusicStream(chip.beep)
    }
    else if chip.sound_timer == 0 && raylib.IsMusicStreamPlaying(chip.beep) {
        raylib.PauseMusicStream(chip.beep)
    }

    delta := raylib.GetFrameTime()
    ips: f32 = 700.0
    instructions_per_frame := ips * delta + chip.remaining_instructions
    ipf := int(instructions_per_frame)
    chip.remaining_instructions = instructions_per_frame - f32(ipf)

    for i in 0..<ipf {
        instruction := fetch(chip)
        execute(chip, instruction)       
    }
}

fetch :: proc(chip: ^Chip8) -> u16 {
    if chip.pc >= len(chip.memory) {
        fmt.println("Out of memory")
        os.exit(-1)
    }

    b1 := u16(chip.memory[chip.pc])
    b2 := u16(chip.memory[chip.pc + 1])
    chip.pc += 2

    return (b1 << 8) | b2
}

execute :: proc(chip: ^Chip8, instruction: u16) {
    // Decode instruction
    op_code := (instruction & 0xF000) >> 12
    x := (instruction & 0x0F00) >> 8 // Used to look up value in registers
    y := (instruction & 0x00F0) >> 4 // Same as above
    n := (instruction & 0x000F) //4-bit number
    nn := (instruction & 0x00FF) // 8-bit number
    nnn := (instruction & 0x0FFF) // 12-bit memory address

    switch op_code {
        case 0x0: {
            switch nn {
                // Clear screen
                case 0xE0: {
                    //fmt.println("CLR")

                    for v, i in chip.display.frame_buffer {
                        chip.display.frame_buffer[i] = false
                    }
                }

                // Return
                case 0xEE: {
                    chip.sp -= 1
                    chip.pc = int(chip.stack[chip.sp])
                }
            }
        }

        // Jump
        case 0x1: {
            chip.pc = int(nnn)
        }

        // Call subroutine
        case 0x2: {
            if chip.sp >= len(chip.stack) {
                fmt.println("No more stack space")
                os.exit(-1)
            }

            chip.stack[chip.sp] = u16(chip.pc)
            chip.sp += 1
            chip.pc = int(nnn)
        }

        // Skip Const EQ
        case 0x3: {
            if u16(chip.reg[x]) == nn {
                chip.pc += 2
            }
        }

        // Skip Const NEQ
        case 0x4: {
            if u16(chip.reg[x]) != nn {
                chip.pc += 2
            }
        }

        // Skip Reg EQ
        case 0x5: {
            if chip.reg[x] == chip.reg[y] {
                chip.pc += 2
            }
        }

        // Set register
        case 0x6: {
            //fmt.printf("SET register %X to %d\n", x, nn)

            chip.reg[x] = u8(nn)
        }

        // Add register
        case 0x7: {
            //fmt.printf("ADD %d to register %X\n", nn, x)

            chip.reg[x] += u8(nn)
        }

        // Logical and arithmetic
        case 0x8: {
            switch n {
                // Set
                case 0x0: {
                    chip.reg[x] = chip.reg[y]
                }

                // Binary OR
                case 0x1: {
                    chip.reg[x] |= chip.reg[y]
                }

                // Binary AND
                case 0x2: {
                    chip.reg[x] &= chip.reg[y]
                }

                // Binary XOR
                case 0x3: {
                    chip.reg[x] ~= chip.reg[y]
                }

                // Add
                case 0x4: {
                    chip.reg[0xF] = 0
                    res := int(chip.reg[x]) + int(chip.reg[y])
                    
                    if res > 255 {
                        chip.reg[0xF] = 1
                    }
                    
                    chip.reg[x] = u8(res)
                }

                // Subtract
                case 0x5: {
                    chip.reg[0xF] = 1
                    res := int(chip.reg[x]) - int(chip.reg[y])
                    
                    if res < 0 {
                        chip.reg[0xF] = 0
                    }

                    chip.reg[x] = u8(res)
                }

                // Right Shift
                case 0x6: {
                    //chip.reg[x] = chip.reg[y]

                    if chip.reg[x] & 1 != 0{
                        chip.reg[0xF] = 1
                    }
                    else {
                        chip.reg[0xF] = 0
                    }

                    chip.reg[x] >>= 1
                }

                // Subtract
                case 0x7: {
                    chip.reg[0xF] = 1
                    res := int(chip.reg[y]) - int(chip.reg[x])
                    
                    if res < 0 {
                        chip.reg[0xF] = 0
                        chip.reg[x] = u8(255 + res)
                    }
                    else {
                        chip.reg[x] = u8(res)
                    }
                }

                // Right Shift
                case 0xE: {
                    //chip.reg[x] = chip.reg[y]

                    if chip.reg[x] & 0b1000_0000 != 0{
                        chip.reg[0xF] = 1
                    }
                    else {
                        chip.reg[0xF] = 0
                    }

                    chip.reg[x] <<= 1
                }
            }
        }

        // Skip Reg NEQ
        case 0x9: {
            if chip.reg[x] != chip.reg[y] {
                chip.pc += 2
            }
        }

        // Set index
        case 0xA: {
            //fmt.printf("SETI index register to %X\n", nnn)
            chip.i = u16(nnn)
        }

        // Jump with offset
        case 0xB: {
            // Old instruction
            chip.pc = int(nnn + u16(chip.reg[0]))
        }

        // Random number
        case 0xC: {
            chip.reg[x] = u8(rand.float32() * 255) & u8(nn)
        }

        // Display
        case 0xD: {
            display := &chip.display
            x_coord: int = int(chip.reg[x]) % display.fb_width
            y_coord: int = int(chip.reg[y]) % display.fb_height
            rows: int = int(n)

            //fmt.printf("DISPLAY sprite %X with %d rows at (%d, %d)\n", chip.i, rows, x_coord, y_coord)

            chip.reg[0xF] = 0

            for row in 0..<rows {
                if y_coord + row >= display.fb_height do break

                sprite: u8 = chip.memory[row + int(chip.i)]

                // Need to use reverse count for getting the sprite pixels because its layed out with the most significant being drawn from left to right
                rev_col := 7
                for col in 0..<8 {
                    if x_coord + col >= display.fb_width do break

                    sp_pixel := sprite & (1 << uint(rev_col)) != 0
                    rev_col -= 1

                    fb_pixel := &display.frame_buffer[(x_coord + col) + (y_coord + row) * display.fb_width]

                    if sp_pixel && fb_pixel^ {
                        fb_pixel^ = false
                        chip.reg[0xF] = 1
                    }
                    else if sp_pixel && !fb_pixel^ {
                        fb_pixel^ = true
                    }
                }
            }
        }

        // Skip if key
        case 0xE: {
            switch nn {
                case 0x9E: {
                    if chip.pad.key[chip.reg[x]] {
                        chip.pc += 2
                    }
                }

                case 0xA1: {
                    if !chip.pad.key[chip.reg[x]] {
                        chip.pc += 2
                    }
                }
            }
        }

        case 0xF: {
            switch nn {
                // Timers
                case 0x07: {
                    chip.reg[x] = chip.delay_timer
                }

                case 0x15: {
                    chip.delay_timer = chip.reg[x]
                }

                case 0x18: {
                    chip.sound_timer = chip.reg[x]
                }

                // Add to index
                case 0x1E: {
                    chip.reg[0xF] = 0
                    res := int(chip.i) + int(chip.reg[x])
                    
                    if res > 0xFFF {
                        chip.reg[0xF] = 1
                    }

                    chip.i = u16(res)
                }

                // Wait for input
                case 0x0A: {
                    key := -1

                    for v, i in chip.pad.key {
                        if v {
                            key = i
                            break
                        }
                    }

                    if key != -1 {
                        chip.reg[x] = u8(key)
                    }
                    else {
                        chip.pc -= 2
                    }
                }

                // Font character
                case 0x29: {
                    chip.i = u16(5 * chip.reg[x] + FONT_ADDRESS)
                }

                // Binary-coded decimal conversion
                case 0x33: {
                    v := chip.reg[x]
                    digit1 := v / 100
                    digit2 := v % 100 / 10
                    digit3 := v % 100 % 10

                    chip.memory[chip.i] = digit1
                    chip.memory[chip.i + 1] = digit2
                    chip.memory[chip.i + 2] = digit3
                }

                // Store reg to mem
                case 0x55: {
                    for i in 0..=x {
                        chip.memory[chip.i + i] = chip.reg[i]
                    }
                }

                // Load mem to reg
                case 0x65: {
                    for i in 0..=x {
                        chip.reg[i] = chip.memory[chip.i + i]
                    }
                }
            }
        }

        case: fmt.printf("Unknown instruction: %X   %X\n", instruction, op_code)
    }
}

update_keypad :: proc(pad: ^Keypad) {
    pad.key[0] = raylib.IsKeyDown(raylib.KeyboardKey.X)
    pad.key[1] = raylib.IsKeyDown(raylib.KeyboardKey.ONE)
    pad.key[2] = raylib.IsKeyDown(raylib.KeyboardKey.TWO)
    pad.key[3] = raylib.IsKeyDown(raylib.KeyboardKey.THREE)
    pad.key[4] = raylib.IsKeyDown(raylib.KeyboardKey.Q)
    pad.key[5] = raylib.IsKeyDown(raylib.KeyboardKey.W)
    pad.key[6] = raylib.IsKeyDown(raylib.KeyboardKey.E)
    pad.key[7] = raylib.IsKeyDown(raylib.KeyboardKey.A)
    pad.key[8] = raylib.IsKeyDown(raylib.KeyboardKey.S)
    pad.key[9] = raylib.IsKeyDown(raylib.KeyboardKey.D)
    pad.key[0xA] = raylib.IsKeyDown(raylib.KeyboardKey.Z)
    pad.key[0xB] = raylib.IsKeyDown(raylib.KeyboardKey.C)
    pad.key[0xC] = raylib.IsKeyDown(raylib.KeyboardKey.FOUR)
    pad.key[0xD] = raylib.IsKeyDown(raylib.KeyboardKey.R)
    pad.key[0xE] = raylib.IsKeyDown(raylib.KeyboardKey.F)
    pad.key[0xF] = raylib.IsKeyDown(raylib.KeyboardKey.V)
}

// This is very scuffed but it works somehow
render :: proc(chip: ^Chip8) {
    raylib.BeginDrawing()
        raylib.ClearBackground(raylib.BLACK)
        
        display := &chip.display
        pixel_w := 0 
        pixel_h := 0
        offset_x := 0
        offset_y := 0
        width := display.width
        height := display.height

        ratio := f32(display.width) / f32(display.height)
        if ratio > 2 {
            offset_x = (display.width - display.height * 2) / 2
            width = display.width - offset_x * 2
        }

        if ratio < 2 {
            offset_y = (display.height - display.width / 2) / 2
            height = display.height - offset_y * 2
        }

        pixel_w = width / display.fb_width
        pixel_h = height / display.fb_height
        
        offset_x += width % display.fb_width / 2
        offset_y += height % display.fb_height / 2

        for y in 0..<chip.display.fb_height {
            for x in 0..<chip.display.fb_width {
                pixel := chip.display.frame_buffer[x + y * chip.display.fb_width]

                if pixel {
                    raylib.DrawRectangle(i32(x * pixel_w + offset_x), i32(y * pixel_h + offset_y), i32(pixel_w), i32(pixel_h), raylib.WHITE)
                }
                else {
                    raylib.DrawRectangle(i32(x * pixel_w + offset_x), i32(y * pixel_h + offset_y), i32(pixel_w), i32(pixel_h), raylib.DARKGRAY)
                }
            }
        }

    raylib.EndDrawing()
}