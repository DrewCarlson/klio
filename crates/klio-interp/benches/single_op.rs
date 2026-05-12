//! Direct Rust-level micros for the absolute hottest runtime ops:
//! `Value::clone`, structural equality, primitive constructors.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use klio_runtime::Value;
use std::cell::RefCell;
use std::rc::Rc;

fn bench_value_clone(c: &mut Criterion) {
    let int = Value::Int(42);
    let s = Value::String(Rc::new("hello world".to_string()));
    let arr = Value::List {
        items: Rc::new(RefCell::new(vec![Value::Int(1), Value::Int(2), Value::Int(3)])),
        mutable: false,
        enum_class: None,
    };
    c.bench_function("value_clone/int", |b| b.iter(|| black_box(int.clone())));
    c.bench_function("value_clone/string", |b| b.iter(|| black_box(s.clone())));
    c.bench_function("value_clone/list", |b| b.iter(|| black_box(arr.clone())));
}

fn bench_value_eq(c: &mut Criterion) {
    let a = Value::Int(100);
    let b = Value::Int(100);
    c.bench_function("value_eq/int", |bn| {
        bn.iter(|| black_box(Value::structural_eq(black_box(&a), black_box(&b))));
    });
    let sa = Value::String(Rc::new("kotlin".to_string()));
    let sb = Value::String(Rc::new("kotlin".to_string()));
    c.bench_function("value_eq/string", |bn| {
        bn.iter(|| black_box(Value::structural_eq(black_box(&sa), black_box(&sb))));
    });
}

criterion_group!(benches, bench_value_clone, bench_value_eq);
criterion_main!(benches);
