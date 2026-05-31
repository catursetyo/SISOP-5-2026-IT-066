int cursor = 0;
char color = 0x07;
int parsedNumber = 0;
int parsedA = 0;
int parsedB = 0;

void putInMemory(int segment, int address, char character);
int getChar();
void clearScreen();
void newline();
void printChar(char c);
void printString(char *s);
void readString(char *buf);
int strcmp(char *a, char *b);
int isCommand(char *cmd, char *name);
int skipSpacesAt(char *s, int idx);
int parseNumberAt(char *s, int idx);
int parseTwoArgs(char *cmd, int start);
int appendDigit(char *out, int pos, int digit);
void intToString(int n, char *out);
int factorial(int n);

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

int isCommand(char *cmd, char *name) {
    int i;

    i = 0;
    while (name[i] != 0) {
        if (cmd[i] != name[i]) {
            return 0;
        }
        i++;
    }

    if (cmd[i] == 0 || cmd[i] == ' ') {
        return 1;
    }

    return 0;
}

int skipSpacesAt(char *s, int idx) {
    while (s[idx] == ' ') {
        idx++;
    }

    return idx;
}

int parseNumberAt(char *s, int idx) {
    int sign;
    int value;
    int found;
    int digit;

    sign = 1;
    value = 0;
    found = 0;

    idx = skipSpacesAt(s, idx);

    if (s[idx] == '-') {
        sign = -1;
        idx++;
    } else if (s[idx] == '+') {
        idx++;
    }

    while (s[idx] >= '0' && s[idx] <= '9') {
        digit = s[idx] - '0';
        value = value * 10;
        value = value + digit;
        found = 1;
        idx++;
    }

    if (!found) {
        return -1;
    }

    parsedNumber = value * sign;
    return idx;
}

int parseTwoArgs(char *cmd, int start) {
    int idx;

    idx = parseNumberAt(cmd, start);
    if (idx < 0) {
        return 0;
    }
    parsedA = parsedNumber;

    idx = parseNumberAt(cmd, idx);
    if (idx < 0) {
        return 0;
    }
    parsedB = parsedNumber;

    idx = skipSpacesAt(cmd, idx);
    if (cmd[idx] != 0) {
        return 0;
    }

    return 1;
}

int appendDigit(char *out, int pos, int digit) {
    if (digit == 0) {
        out[pos] = '0';
    } else if (digit == 1) {
        out[pos] = '1';
    } else if (digit == 2) {
        out[pos] = '2';
    } else if (digit == 3) {
        out[pos] = '3';
    } else if (digit == 4) {
        out[pos] = '4';
    } else if (digit == 5) {
        out[pos] = '5';
    } else if (digit == 6) {
        out[pos] = '6';
    } else if (digit == 7) {
        out[pos] = '7';
    } else if (digit == 8) {
        out[pos] = '8';
    } else {
        out[pos] = '9';
    }

    return pos + 1;
}

void intToString(int n, char *out) {
    int j;
    int digit;
    int started;

    if (n == 0) {
        out[0] = '0';
        out[1] = 0;
        return;
    }

    j = 0;
    if (n < 0) {
        if (n == -32767 - 1) {
            out[0] = '-';
            out[1] = '3';
            out[2] = '2';
            out[3] = '7';
            out[4] = '6';
            out[5] = '8';
            out[6] = 0;
            return;
        }

        out[j] = '-';
        j++;
        n = -n;
    }

    started = 0;

    digit = 0;
    while (n >= 10000) {
        n = n - 10000;
        digit++;
    }
    if (digit > 0) {
        j = appendDigit(out, j, digit);
        started = 1;
    }

    digit = 0;
    while (n >= 1000) {
        n = n - 1000;
        digit++;
    }
    if (digit > 0 || started) {
        j = appendDigit(out, j, digit);
        started = 1;
    }

    digit = 0;
    while (n >= 100) {
        n = n - 100;
        digit++;
    }
    if (digit > 0 || started) {
        j = appendDigit(out, j, digit);
        started = 1;
    }

    digit = 0;
    while (n >= 10) {
        n = n - 10;
        digit++;
    }
    if (digit > 0 || started) {
        j = appendDigit(out, j, digit);
        started = 1;
    }

    digit = 0;
    while (n >= 1) {
        n = n - 1;
        digit++;
    }
    j = appendDigit(out, j, digit);

    out[j] = 0;
}

int factorial(int n) {
    int i;
    int result;

    result = 1;
    i = 2;
    while (i <= n) {
        result = result * i;
        i++;
    }

    return result;
}

void main() {

    char cmd[64];
    char number[16];
    int a;
    int b;
    int result;
    int idx;

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
        } else if (isCommand(cmd, "add")) {
            if (parseTwoArgs(cmd, 3)) {
                a = parsedA;
                b = parsedB;
                result = a + b;
                intToString(result, number);
                printString(number);
            } else {
                printString("usage: add <a> <b>");
            }
        } else if (isCommand(cmd, "sub")) {
            if (parseTwoArgs(cmd, 3)) {
                a = parsedA;
                b = parsedB;
                result = a - b;
                intToString(result, number);
                printString(number);
            } else {
                printString("usage: sub <a> <b>");
            }
        } else if (isCommand(cmd, "fac")) {
            idx = parseNumberAt(cmd, 3);
            if (idx >= 0) {
                a = parsedNumber;
                idx = skipSpacesAt(cmd, idx);
                if (cmd[idx] == 0 && a >= 0 && a <= 7) {
                    result = factorial(a);
                    intToString(result, number);
                    printString(number);
                } else {
                    printString("know your limit little bro.");
                }
            } else {
                printString("usage: fac <n>");
            }
        } else if (strcmp(cmd, "help")) {
            printString("check add sub fac help about");
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
