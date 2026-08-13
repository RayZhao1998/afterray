//! AC power probe. Fail closed: unknown / error means "not on AC".

#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::array::CFArray;
    use core_foundation::base::{CFRelease, CFTypeRef, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
        fn IOPSCopyPowerSourcesList(blob: CFTypeRef) -> CFTypeRef;
        fn IOPSGetPowerSourceDescription(blob: CFTypeRef, ps: CFTypeRef) -> CFTypeRef;
    }

    pub fn on_ac_power() -> bool {
        unsafe {
            let info = IOPSCopyPowerSourcesInfo();
            if info.is_null() {
                return false;
            }
            let list_ref = IOPSCopyPowerSourcesList(info);
            if list_ref.is_null() {
                CFRelease(info);
                return false;
            }
            let list = CFArray::<CFTypeRef>::wrap_under_create_rule(list_ref.cast());
            let state_key = CFString::from_static_string("Power Source State");
            let mut on_ac = false;
            for source in list.iter() {
                let description = IOPSGetPowerSourceDescription(info, *source);
                if description.is_null() {
                    continue;
                }
                let dict = CFDictionary::<CFString, CFString>::wrap_under_get_rule(description.cast());
                if let Some(state) = dict.find(&state_key) {
                    let state = state.to_string();
                    if state == "AC Power" {
                        on_ac = true;
                        break;
                    }
                }
            }
            CFRelease(info);
            on_ac
        }
    }
}

#[cfg(target_os = "macos")]
#[must_use]
pub fn on_ac_power() -> bool {
    macos::on_ac_power()
}

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn on_ac_power() -> bool {
    true
}
