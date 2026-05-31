int cursor = 0;
char color = 0x07;

void putInMemory(int segment, int address, char character);
int getChar();
void clearScreen();
void newline();
void printChar(char c);
void printString(char *s);
void readString(char *buf);
int strcmp(char *a, char *b);

/*
 * Final Challenge
 *
 * Commands:
 * - check
 * - add <a> <b>
 * - sub <a> <b>
 * - fac <n>
 * - season <name>
 * - triangle <n>
 * - clear
 * - about
 *
 * Season list:
 * - winter
 * - spring
 * - summer
 * - fall
 * - radiant
 *
 * Restrictions:
 * - no stdlib
 * - avoid division (/)
 * - avoid modulo (%)
 */

void clearScreen() {
    int i;
    int pos;

    i = 0;
    while (i < 2000) {
        pos = i * 2;
        putInMemory(0xB800, pos, ' ');
        putInMemory(0xB800, pos + 1, color);
        i++;
    }

    cursor = 0;
}

void newline() {
    int col;

    col = cursor;
    while (col >= 80) {
        col = col - 80;
    }

    cursor = cursor + (80 - col);
    if (cursor >= 2000) {
        clearScreen();
    }
}

void printChar(char c) {
    int pos;

    if (c == '\n') {
        newline();
        return;
    }

    if (c == 8) {
        if (cursor > 0) {
            cursor--;
            pos = cursor * 2;
            putInMemory(0xB800, pos, ' ');
            putInMemory(0xB800, pos + 1, color);
        }
        return;
    }

    if (cursor >= 2000) {
        clearScreen();
    }

    pos = cursor * 2;
    putInMemory(0xB800, pos, c);
    putInMemory(0xB800, pos + 1, color);
    cursor++;

    if (cursor >= 2000) {
        clearScreen();
    }
}

void printString(char *s) {
    int i;

    i = 0;
    while (s[i] != 0) {
        printChar(s[i]);
        i++;
    }
}

void readString(char *buf) {
    int i;
    char c;

    i = 0;
    while (1) {
        c = getChar();

        if (c == 13) {
            buf[i] = 0;
            return;
        }

        if (c == 8) {
            if (i > 0) {
                i--;
                printChar(8);
            }
        } else {
            if (c >= 32 && c <= 126 && i < 63) {
                buf[i] = c;
                i++;
                printChar(c);
            }
        }
    }
}

int strcmp(char *a, char *b) {
    int i;

    i = 0;
    while (a[i] != 0 && b[i] != 0) {
        if (a[i] != b[i]) {
            return 0;
        }
        i++;
    }

    if (a[i] == 0 && b[i] == 0) {
        return 1;
    }

    return 0;
}

void main() {

    char cmd[64];

    clearScreen();

    printString("Welcome to Assistant's Last Gift");
    newline();

    printString("type 'help'");
    newline();
    newline();

    while (1) {

        printString("> ");

        readString(cmd);

        newline();

        if (strcmp(cmd, "check")) {
            printString("ok");
        } else if (strcmp(cmd, "help")) {
            printString("check help about");
        } else if (strcmp(cmd, "about")) {
            printString("Assistant's Last Gift");
        } else if (strcmp(cmd, "")) {
            printString("");
        } else {
            printString("unknown command");
        }

        newline();
    }
}
