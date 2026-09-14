import SwiftUI

struct FirstMateInspectorPresentation: ViewModifier {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot?
    @Binding var isPresented: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content.inspector(isPresented: $isPresented) {
                Group {
                    if isPresented, let snapshot {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Feature details").font(.headline)
                                Spacer(minLength: 12)
                                Button("Done") { isPresented = false }
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("first-mate-inspector-done")
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)
                            FirstMateInspectorView(store: store, snapshot: snapshot)
                        }
                    }
                }
                .background(FirstMatePalette(scheme: scheme).background)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 460)
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NavigationStack {
                    if let snapshot {
                        FirstMateInspectorView(store: store, snapshot: snapshot)
                            .navigationTitle("Feature details")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarColorScheme(scheme, for: .navigationBar)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { isPresented = false }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .accessibilityIdentifier("first-mate-inspector-done")
                                }
                                .sharedBackgroundVisibility(.hidden)
                            }
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}
