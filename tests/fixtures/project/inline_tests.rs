fn helper() {}

#[cfg(test)]
mod tests {
    #[test]
    fn helper_is_available() {
        super::helper();
    }
}
