module negative_handle_constructor;
import concurrency : TaskHandle;
void main() { auto handle = new TaskHandle!int(null); }
