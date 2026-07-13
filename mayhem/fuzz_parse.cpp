#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include <unistd.h>

#include <fuzzer/FuzzedDataProvider.h>

#include <highfive/H5Easy.hpp>
#include <highfive/H5File.hpp>

using namespace HighFive;

// Mayhem runs this target as several concurrent libFuzzer worker processes sharing one filesystem
// (and the triager replays crashes alongside them). A fixed scratch path is therefore contended:
// two processes calling H5Fcreate on the same file race on HDF5's flock, and the loser throws
// HighFive::FileException("Unable to lock file") out of LLVMFuzzerTestOneInput, which terminate()s
// and is filed as an "Uncaught Exception" defect that says nothing about HighFive. Give every
// process its own directory instead, honouring TMPDIR so the path follows the sandbox's scratch
// space. Created once per process, not once per input.
static const std::string& scratch_file() {
    static const std::string path = [] {
        const char* env = std::getenv("TMPDIR");
        std::string base = (env && *env) ? env : "/tmp";
        while (base.size() > 1 && base.back() == '/') {
            base.pop_back();
        }
        std::string tmpl = base + "/highfive_fuzz_XXXXXX";
        std::vector<char> buf(tmpl.begin(), tmpl.end());
        buf.push_back('\0');
        const char* dir = mkdtemp(buf.data());
        if (!dir) {
            abort();
        }
        return std::string(dir) + "/fuzz.h5";
    }();
    return path;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* fuzz_data, size_t size) {
    if (size < 1) {
        return -1;
    }
    FuzzedDataProvider fdp(fuzz_data, size);

    auto test_matrix = fdp.ConsumeBool();

    if (test_matrix) {
        File file(scratch_file(), File::Truncate);
        auto size_x = fdp.ConsumeIntegralInRange<size_t>(1, 100);
        auto size_y = fdp.ConsumeIntegralInRange<size_t>(1, 100);

        std::vector<std::vector<double>> matrix(size_x, std::vector<double>(size_y));
        std::vector<std::vector<double>> result;

        for (std::size_t i = 0; i < size_x; ++i) {
            for (std::size_t j = 0; j < size_y; ++j) {
                matrix[i][j] = fdp.ConsumeFloatingPoint<double>();
            }
        }

        auto dataset = file.createDataSet<double>("data", DataSpace::From(matrix));
        dataset.write(matrix);
        dataset.read(result);
    } else {
        H5Easy::File file(scratch_file(), H5Easy::File::Overwrite);
        H5Easy::dump(file, "data", fdp.ConsumeRemainingBytesAsString());

        auto contents = H5Easy::load<std::string>(file, "data");
    }
    return 0;
}
