use chatcore::mls::*;
#[test]
fn two_devices_agree() {
    let a = Device::new(b"alice/a1").unwrap();
    let b = Device::new(b"bob/b1").unwrap();
    let mut ga = a.create_group().unwrap();
    let out = a.add(&mut ga, &[b.key_package().unwrap()]).unwrap();
    let mut gb = b.join_welcome(&out.welcome.unwrap()).unwrap();
    assert_eq!(ga.epoch(), gb.epoch());
    assert_eq!(a.sframe_key(&ga, b"c").unwrap(), b.sframe_key(&gb, b"c").unwrap());
    let ct = a.encrypt(&mut ga, b"hi").unwrap();
    assert_eq!(b.decrypt(&mut gb, &ct).unwrap(), b"hi");
}
