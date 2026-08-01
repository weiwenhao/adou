#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 64;
    if (setpgid(0, 0) != 0) return 125;
    execvp(argv[1], &argv[1]);
    return 127;
}
