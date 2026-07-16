# Discover the test cases registered in a Boost.Test executable and expose
# each of them as a separate CTest test.  Discovery runs after the executable
# is linked, so changes to the registered test tree do not require parsing the
# C++ sources or rerunning CMake.

include_guard(GLOBAL)

cmake_policy(PUSH)
cmake_policy(VERSION 3.15)

set_property(GLOBAL PROPERTY QL_DISCOVER_BOOST_TESTS_SCRIPT
    "${CMAKE_CURRENT_LIST_FILE}")

function(ql_discover_boost_tests target)
    cmake_parse_arguments(
        arg
        ""
        "WORKING_DIRECTORY;TEST_PREFIX;TEST_SUFFIX;DISCOVERY_TIMEOUT"
        "EXTRA_ARGS;PROPERTIES"
        ${ARGN})

    if (NOT TARGET ${target})
        message(FATAL_ERROR "ql_discover_boost_tests: '${target}' is not a target")
    endif()

    if (NOT arg_WORKING_DIRECTORY)
        set(arg_WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
    endif()
    if (NOT arg_DISCOVERY_TIMEOUT)
        set(arg_DISCOVERY_TIMEOUT 30)
    endif()

    get_property(discovery_count TARGET ${target}
        PROPERTY QL_CTEST_DISCOVERY_COUNT)
    if (discovery_count)
        math(EXPR discovery_count "${discovery_count} + 1")
    else()
        set(discovery_count 1)
    endif()
    set_property(TARGET ${target} PROPERTY QL_CTEST_DISCOVERY_COUNT
        ${discovery_count})

    get_property(crosscompiling_emulator TARGET ${target}
        PROPERTY CROSSCOMPILING_EMULATOR)
    get_property(discovery_script GLOBAL
        PROPERTY QL_DISCOVER_BOOST_TESTS_SCRIPT)

    set(test_file_base
        "${CMAKE_CURRENT_BINARY_DIR}/${target}[${discovery_count}]")
    set(test_include_file "${test_file_base}_include.cmake")
    set(test_list_file "${test_file_base}_tests.cmake")

    add_custom_command(
        TARGET ${target} POST_BUILD
        BYPRODUCTS "${test_list_file}"
        COMMAND "${CMAKE_COMMAND}"
            -D "QL_BOOST_TEST_DISCOVERY=ON"
            -D "TEST_EXECUTABLE=$<TARGET_FILE:${target}>"
            -D "TEST_EXECUTOR=${crosscompiling_emulator}"
            -D "TEST_WORKING_DIRECTORY=${arg_WORKING_DIRECTORY}"
            -D "TEST_PREFIX=${arg_TEST_PREFIX}"
            -D "TEST_SUFFIX=${arg_TEST_SUFFIX}"
            -D "TEST_EXTRA_ARGS=${arg_EXTRA_ARGS}"
            -D "TEST_PROPERTIES=${arg_PROPERTIES}"
            -D "TEST_LIST_FILE=${test_list_file}"
            -D "TEST_DISCOVERY_TIMEOUT=${arg_DISCOVERY_TIMEOUT}"
            -P "${discovery_script}"
        VERBATIM)

    file(WRITE "${test_include_file}"
        "if(EXISTS \"${test_list_file}\")\n"
        "    include(\"${test_list_file}\")\n"
        "else()\n"
        "    add_test(${target}_NOT_BUILT ${target}_NOT_BUILT)\n"
        "endif()\n")

    set_property(DIRECTORY APPEND PROPERTY TEST_INCLUDE_FILES
        "${test_include_file}")
endfunction()

function(_ql_bracket_quote value output_variable)
    set(equals "")
    while (TRUE)
        string(FIND "${value}" "]${equals}]" delimiter_position)
        if (delimiter_position EQUAL -1)
            break()
        endif()
        string(APPEND equals "=")
    endwhile()
    set(${output_variable} "[${equals}[${value}]${equals}]" PARENT_SCOPE)
endfunction()

function(_ql_append_argument command_variable value)
    _ql_bracket_quote("${value}" quoted_value)
    set(${command_variable} "${${command_variable}} ${quoted_value}" PARENT_SCOPE)
endfunction()

function(_ql_discover_boost_tests_impl)
    if (NOT EXISTS "${TEST_EXECUTABLE}")
        message(FATAL_ERROR
            "Boost.Test discovery executable does not exist: '${TEST_EXECUTABLE}'")
    endif()

    execute_process(
        COMMAND ${TEST_EXECUTOR} "${TEST_EXECUTABLE}" --list_content=HRF
        WORKING_DIRECTORY "${TEST_WORKING_DIRECTORY}"
        TIMEOUT ${TEST_DISCOVERY_TIMEOUT}
        OUTPUT_VARIABLE discovery_stdout
        ERROR_VARIABLE discovery_stderr
        RESULT_VARIABLE discovery_result)

    if (NOT discovery_result EQUAL 0)
        message(FATAL_ERROR
            "Boost.Test discovery failed for '${TEST_EXECUTABLE}' "
            "(exit code ${discovery_result}):\n"
            "${discovery_stdout}${discovery_stderr}")
    endif()

    # Boost.Test writes the human-readable test tree to its report stream,
    # which is stderr by default.  Preserve stdout as well for configurations
    # that redirect the report stream.
    set(discovery_output "${discovery_stdout}${discovery_stderr}")
    string(REPLACE "\r\n" "\n" discovery_output "${discovery_output}")
    string(REPLACE "\r" "\n" discovery_output "${discovery_output}")
    string(REPLACE ";" "\\;" discovery_output "${discovery_output}")
    string(REPLACE "\n" ";" discovery_lines "${discovery_output}")

    set(test_script "")
    set(suite_stack "")
    set(test_count 0)
    list(LENGTH discovery_lines line_count)

    if (line_count GREATER 0)
        math(EXPR last_line "${line_count} - 1")
        foreach(line_index RANGE 0 ${last_line})
            list(GET discovery_lines ${line_index} line)
            if (line STREQUAL "")
                continue()
            endif()

            string(REGEX MATCH "^ +" indentation "${line}")
            string(LENGTH "${indentation}" indentation_width)
            math(EXPR indentation_remainder "${indentation_width} % 4")
            if (NOT indentation_remainder EQUAL 0)
                message(FATAL_ERROR
                    "Unexpected indentation in Boost.Test discovery output: '${line}'")
            endif()
            math(EXPR depth "${indentation_width} / 4")

            string(SUBSTRING "${line}" ${indentation_width} -1 entry)
            # Descriptions, when present, follow the enabled/disabled marker.
            string(REGEX REPLACE "([* ])(: .*)$" "\\1" entry "${entry}")
            string(LENGTH "${entry}" entry_length)
            if (entry_length LESS 2)
                message(FATAL_ERROR
                    "Unexpected Boost.Test discovery entry: '${line}'")
            endif()
            math(EXPR marker_index "${entry_length} - 1")
            string(SUBSTRING "${entry}" ${marker_index} 1 status_marker)
            string(SUBSTRING "${entry}" 0 ${marker_index} entry_name)
            if (NOT status_marker STREQUAL "*" AND
                    NOT status_marker STREQUAL " ")
                message(FATAL_ERROR
                    "Missing status marker in Boost.Test discovery entry: '${line}'")
            endif()

            # A suite is followed by a more deeply indented entry.  Test cases
            # are leaves in the reported tree.
            set(is_suite FALSE)
            math(EXPR next_line_index "${line_index} + 1")
            while (next_line_index LESS line_count)
                list(GET discovery_lines ${next_line_index} next_line)
                if (NOT next_line STREQUAL "")
                    string(REGEX MATCH "^ +" next_indentation "${next_line}")
                    string(LENGTH "${next_indentation}" next_indentation_width)
                    if (next_indentation_width GREATER indentation_width)
                        set(is_suite TRUE)
                    endif()
                    break()
                endif()
                math(EXPR next_line_index "${next_line_index} + 1")
            endwhile()

            list(LENGTH suite_stack stack_length)
            while (stack_length GREATER depth)
                math(EXPR stack_last "${stack_length} - 1")
                list(REMOVE_AT suite_stack ${stack_last})
                list(LENGTH suite_stack stack_length)
            endwhile()

            if (is_suite)
                list(APPEND suite_stack "${entry_name}")
                continue()
            endif()

            set(qualified_name "")
            foreach(suite_name IN LISTS suite_stack)
                if (qualified_name)
                    string(APPEND qualified_name "/")
                endif()
                string(APPEND qualified_name "${suite_name}")
            endforeach()
            if (qualified_name)
                string(APPEND qualified_name "/")
            endif()
            string(APPEND qualified_name "${entry_name}")
            set(ctest_name "${TEST_PREFIX}${qualified_name}${TEST_SUFFIX}")

            _ql_bracket_quote("${ctest_name}" quoted_test_name)
            set(add_test_command "add_test(${quoted_test_name}")
            foreach(command_part IN LISTS TEST_EXECUTOR)
                _ql_append_argument(add_test_command "${command_part}")
            endforeach()
            _ql_append_argument(add_test_command "${TEST_EXECUTABLE}")
            _ql_append_argument(add_test_command "--run_test=${qualified_name}")
            foreach(extra_arg IN LISTS TEST_EXTRA_ARGS)
                _ql_append_argument(add_test_command "${extra_arg}")
            endforeach()
            string(APPEND add_test_command ")\n")
            string(APPEND test_script "${add_test_command}")

            set(property_command
                "set_tests_properties(${quoted_test_name} PROPERTIES")
            _ql_append_argument(property_command "WORKING_DIRECTORY")
            _ql_append_argument(property_command "${TEST_WORKING_DIRECTORY}")
            foreach(test_property IN LISTS TEST_PROPERTIES)
                _ql_append_argument(property_command "${test_property}")
            endforeach()
            if (status_marker STREQUAL " ")
                _ql_append_argument(property_command "DISABLED")
                _ql_append_argument(property_command "TRUE")
            endif()
            string(APPEND property_command ")\n")
            string(APPEND test_script "${property_command}")

            math(EXPR test_count "${test_count} + 1")
        endforeach()
    endif()

    if (test_count EQUAL 0)
        message(FATAL_ERROR
            "Boost.Test discovery found no test cases in '${TEST_EXECUTABLE}'")
    endif()

    file(WRITE "${TEST_LIST_FILE}" "${test_script}")
    message(STATUS "Discovered ${test_count} Boost.Test cases in ${TEST_EXECUTABLE}")
endfunction()

cmake_policy(POP)

if (CMAKE_SCRIPT_MODE_FILE AND QL_BOOST_TEST_DISCOVERY)
    _ql_discover_boost_tests_impl()
endif()
