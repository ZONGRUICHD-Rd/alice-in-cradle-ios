// CoreServices UCKeyTranslate US ANSI keycode translator for Unity macOS input on iOS 27.
#import <Foundation/Foundation.h>
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

static unichar TranslateANSIKeyCode(uint16_t keyCode, BOOL shift) {
    switch (keyCode) {
        case 0: return shift ? 'A' : 'a';
        case 1: return shift ? 'S' : 's';
        case 2: return shift ? 'D' : 'd';
        case 3: return shift ? 'F' : 'f';
        case 4: return shift ? 'H' : 'h';
        case 5: return shift ? 'G' : 'g';
        case 6: return shift ? 'Z' : 'z';
        case 7: return shift ? 'X' : 'x';
        case 8: return shift ? 'C' : 'c';
        case 9: return shift ? 'V' : 'v';
        case 11: return shift ? 'B' : 'b';
        case 12: return shift ? 'Q' : 'q';
        case 13: return shift ? 'W' : 'w';
        case 14: return shift ? 'E' : 'e';
        case 15: return shift ? 'R' : 'r';
        case 16: return shift ? 'Y' : 'y';
        case 17: return shift ? 'T' : 't';
        case 18: return shift ? '!' : '1';
        case 19: return shift ? '@' : '2';
        case 20: return shift ? '#' : '3';
        case 21: return shift ? '$' : '4';
        case 22: return shift ? '^' : '6';
        case 23: return shift ? '%' : '5';
        case 24: return shift ? '+' : '=';
        case 25: return shift ? '(' : '9';
        case 26: return shift ? '&' : '7';
        case 27: return shift ? '_' : '-';
        case 28: return shift ? '*' : '8';
        case 29: return shift ? ')' : '0';
        case 30: return shift ? '}' : ']';
        case 31: return shift ? 'O' : 'o';
        case 32: return shift ? 'U' : 'u';
        case 33: return shift ? '{' : '[';
        case 34: return shift ? 'I' : 'i';
        case 35: return shift ? 'P' : 'p';
        case 36: return '\r';
        case 37: return shift ? 'L' : 'l';
        case 38: return shift ? 'J' : 'j';
        case 39: return shift ? '"' : '\'';
        case 40: return shift ? 'K' : 'k';
        case 41: return shift ? ':' : ';';
        case 42: return shift ? '|' : '\\';
        case 43: return shift ? '<' : ',';
        case 44: return shift ? '?' : '/';
        case 45: return shift ? 'N' : 'n';
        case 46: return shift ? 'M' : 'm';
        case 47: return shift ? '>' : '.';
        case 48: return '\t';
        case 49: return ' ';
        case 50: return shift ? '~' : '`';
        case 51: return 0x08; // Backspace
        case 53: return 0x1b; // Escape
        case 123: return 0xF702; // Left Arrow
        case 124: return 0xF703; // Right Arrow
        case 125: return 0xF701; // Down Arrow
        case 126: return 0xF700; // Up Arrow
        default: return 0;
    }
}

EXPORT OSStatus UCKeyTranslate(
    const void *keyLayoutPtr,
    uint16_t virtualKeyCode,
    uint16_t keyAction,
    uint32_t modifierKeyState,
    uint32_t keyboardType,
    uint32_t keyTranslateOptions,
    uint32_t *deadKeyState,
    unsigned long maxStringLength,
    unsigned long *actualStringLength,
    unichar *unicodeString
) {
    (void)keyLayoutPtr; (void)keyAction; (void)keyboardType; (void)keyTranslateOptions;
    if (deadKeyState) *deadKeyState = 0;
    BOOL shift = (modifierKeyState & 0x02) != 0;
    unichar ch = TranslateANSIKeyCode(virtualKeyCode, shift);
    if (ch != 0 && maxStringLength >= 1 && unicodeString) {
        unicodeString[0] = ch;
        if (actualStringLength) *actualStringLength = 1;
    } else {
        if (actualStringLength) *actualStringLength = 0;
    }
    return noErr;
}
