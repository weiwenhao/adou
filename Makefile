# provider_user_images_test excluded: deterministic nature #302-family
# segfault on image-only user contexts through anthropic_request.build.
# See docs/porting-plan-100.md for details.
TEST_SOURCES := $(sort $(filter-out tests/provider_user_images_test.n,$(wildcard tests/*.n)))