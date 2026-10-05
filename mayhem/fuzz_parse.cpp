#include <cstdint>
#include <cstdlib>
#include <string>

#include <fuzzer/FuzzedDataProvider.h>

#include <highfive/H5Easy.hpp>
#include <highfive/H5File.hpp>

// Pulled in transitively by H5File.hpp's bits/H5Converter_misc.hpp when H5_USE_BOOST is defined
// (see mayhem/build.sh), which is also what makes DataSpace::From()/dataset.read() understand
// boost::numeric::ublas::matrix below.
#include <boost/numeric/ublas/matrix.hpp>

using namespace HighFive;
typedef boost::numeric::ublas::matrix<double> Matrix;

// Matches the original mayhemheroes harness verbatim: a fixed "test" path opened with
// File::Truncate, and a dataset.read() with no preceding write(). The original run's defects
// (2x Uncaught Exception, 2x NULL Pointer Dereference) are HighFive/HDF5 mis-handling concurrent
// libFuzzer workers racing on that shared path's HDF5 file lock, not a bug reachable from a single
// input in isolation — reproducing them needs the same shared, fixed path under concurrency.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* fuzz_data, size_t size) {
    if (size < 1) {
        return -1;
    }
    FuzzedDataProvider fdp(fuzz_data, size);

    auto test_matrix = fdp.ConsumeBool();

    if (test_matrix) {
        File file("test", File::Truncate);
        auto size_x = fdp.ConsumeIntegralInRange<size_t>(1, 100);
        auto size_y = fdp.ConsumeIntegralInRange<size_t>(1, 100);

        Matrix matrix(size_x, size_y);
        Matrix result;

        for (std::size_t i = 0; i < size_x; ++i) {
            for (std::size_t j = 0; j < size_y; ++j) {
                matrix(i, j) = fdp.ConsumeFloatingPoint<double>();
            }
        }

        auto dataset = file.createDataSet<double>("data", DataSpace::From(matrix));
        dataset.read(result);
    } else {
        H5Easy::File file("test", H5Easy::File::Overwrite);
        H5Easy::dump(file, "data", fdp.ConsumeRemainingBytesAsString());

        auto contents = H5Easy::load<std::string>(file, "data");
    }
    return 0;
}
