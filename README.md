# zig-evdev

A Zig wrapper for [libevdev](https://www.freedesktop.org/software/libevdev/doc/latest/) with High-Level API

## Status

- Initialization and setup
    - [x] new
    - [x] new_from_fd
    - [x] free
    - [x] grab
    - [ ] set_fd
    - [ ] change_fd
    - [x] get_fd
- Library logging facilities
    - [ ] ...
- Querying device capabilities
    - [x] get_name
    - [ ] get_phys
    - [ ] get_uniq
    - [ ] get_id_product
    - [ ] get_id_vendor
    - [ ] get_id_bustype
    - [ ] get_id_version
    - [ ] get_driver_version
    - [x] has_property
    - [x] has_event_type
    - [x] has_event_code
    - [x] get_abs_info
        - [ ] get_abs_minimum
        - [ ] get_abs_maximum
        - [ ] get_abs_fuzz
        - [ ] get_abs_flat
        - [ ] get_abs_resolution
    - [ ] get_event_value
    - [ ] fetch_event_value
    - [ ] get_repeat
- Multi-touch related functions
    - [ ] get_slot_value
    - [ ] fetch_slot_value
    - [x] get_num_slots
    - [ ] get_current_slot
- Modifying the appearance or capabilities of the device
    - [x] set_name
    - [ ] set_phys
    - [ ] set_uniq
    - [ ] set_id_product
    - [ ] set_id_vendor
    - [ ] set_id_bustype
    - [ ] set_id_version
    - [x] enable_property
    - [x] disable_property
    - [ ] set_event_value
    - [ ] set_slot_value
    - [ ] set_abs_info
        - [ ] set_abs_minimum
        - [ ] set_abs_maximum
        - [ ] set_abs_fuzz
        - [ ] set_abs_flat
        - [ ] set_abs_resolution
    - [x] enable_event_type
    - [x] disable_event_type
    - [x] enable_event_code
    - [x] disable_event_code
    - [ ] kernel_set_abs_info
    - [ ] kernel_set_led_value
    - [ ] kernel_set_led_values
    - [ ] set_clock_id
- Miscellaneous helper functions
    - [ ] ...
- Event handling
    - [x] next_event
    - [ ] has_event_pending
- uinput device creation
    - [x] uinput_create_from_device
    - [x] uinput_destroy
    - [x] get_fd
    - [x] get_syspath
    - [x] get_devnode
    - [x] get_write_event

## License

This repository is licensed under the [MIT license](./LICENSE).
