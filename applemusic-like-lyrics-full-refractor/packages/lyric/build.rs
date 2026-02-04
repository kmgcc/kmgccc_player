fn main() {
    println!("cargo:rerun-if-changed=./src/types.d.ts");

    let types = std::fs::read_to_string("./src/types.d.ts").expect("Can't read types.d.ts");
    let out_path = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
    std::fs::write(
        out_path.join("types.rs"),
        format!(
            r######"use wasm_bindgen::prelude::*;
#[wasm_bindgen(typescript_custom_section)]
const TS_TYPES: &str = r###"{types}"###;
"######
        ),
    )
    .expect("Can't write types.rs");
}
