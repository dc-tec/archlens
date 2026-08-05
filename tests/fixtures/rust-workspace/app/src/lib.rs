use archlens_core::Core;
use archlens_renamed::Renamed;

pub fn run(core: Core, renamed: Renamed) -> usize {
    core.value() + renamed.value()
}

#[cfg(test)]
mod tests {
    use super::*;
    use archlens_dev_helper::fixture;

    #[test]
    fn combines_values() {
        assert_eq!(run(Core, Renamed), fixture());
    }
}
