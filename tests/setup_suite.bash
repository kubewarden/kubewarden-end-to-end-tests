# Output: [basic-tests.bats]
tfile() { echo -n "[${BATS_TEST_FILENAME##*/}]"; }
export -f tfile

setup_suite() {
    # bats::on_failure hook requires >= 1.12.0
    bats_require_minimum_version 1.11.0

    load "../helpers/helpers.sh"
}
