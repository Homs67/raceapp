//
//  ProfileView.swift
//  raceApp
//
//  The Profile tab (design/profile, Figma "Profile — iPhone 17 Pro"):
//  you (photo, name, email, joined), the garage, track achievements, and
//  highlights — totals and personal records for a period. Settings opens
//  from the gear.
//

import SwiftUI
import PhotosUI
import SessionKit

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    @AppStorage(ProfileKeys.firstName) private var firstName = ""
    @AppStorage(ProfileKeys.lastName) private var lastName = ""
    @AppStorage(ProfileKeys.email) private var email = ""
    @State private var period: StatsPeriod = .allTime
    @State private var manifests: [SessionManifest] = []
    @State private var editing = false
    @State private var addingCar = false
    @State private var photoFor: GarageCar?
    @State private var editingCar: GarageCar?

    private let grid = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    garage
                    achievements
                    highlights
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color.bgScreen)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: UUID.self) { SessionDetailView(sessionId: $0) }
            .sheet(isPresented: $editing) { EditProfileSheet() }
            .sheet(isPresented: $addingCar) { AddCarSheet().environment(model) }
            .sheet(item: $editingCar) { AddCarSheet(editing: $0).environment(model) }
        }
        .task(id: model.recording.sessionsVersion) { manifests = model.store.list() }
    }

    // MARK: You

    private var fullName: String {
        let n = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Your name" : n
    }

    private var header: some View {
        Button { editing = true } label: {
            VStack(spacing: 0) {
                ProfilePhotoView(size: 104)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                            .background(Color.accent, in: Circle())
                            .overlay(Circle().stroke(Color.bgScreen, lineWidth: 3))
                    }
                    .padding(.bottom, 16)
                Text(fullName)
                    .font(.sofia(30, .bold))
                    .foregroundStyle(firstName.isEmpty && lastName.isEmpty ? Color.muted : Color.textPrimary)
                if !email.isEmpty {
                    Text(email)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mutedStrong)
                        .padding(.top, 2)
                }
                Text("Joined \(ProfileKeys.joined(manifests).formatted(.dateTime.month(.abbreviated).year()))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.muted)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityHint("Edit profile")
    }

    // MARK: Garage

    private var garage: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Garage") {
                Button("Add a car") { addingCar = true }
            }
            let several = model.garage.cars.count > 1
            ForEach(model.garage.cars) { car in
                GarageRow(car: car, photo: model.garage.photo(for: car), stats: stats(for: car),
                          selected: several && car.id == model.garage.active?.id, metric: metric,
                          photoVersion: model.garage.photoVersion)
                    .onTapGesture { if several { withAnimation(.snappy) { model.garage.setActive(car) } } }
                    .contextMenu {
                        if several, car.id != model.garage.active?.id {
                            Button { model.garage.setActive(car) } label: { Label("Drive this car", systemImage: "checkmark.circle") }
                        }
                        Button { editingCar = car } label: { Label("Edit car", systemImage: "pencil") }
                        Button { photoFor = car } label: { Label("Change photo", systemImage: "camera") }
                        Button(role: .destructive) { model.garage.remove(car) } label: { DestructiveLabel("Remove") }
                    }
            }
            if model.garage.cars.isEmpty {
                Text("Add the car you drive: snap a photo and the background is removed for you.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
            }
        }
        .photosPicker(isPresented: Binding(get: { photoFor != nil }, set: { if !$0 { photoFor = nil } }),
                      selection: Binding(get: { nil }, set: { item in
                          guard let item, let car = photoFor else { return }
                          Task {
                              if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                                  await model.garage.setPhoto(img, for: car.id)
                              }
                          }
                      }), matching: .images)
    }

    /// One car: its sessions; the only car: every session.
    private func stats(for car: GarageCar) -> (sessions: Int, meters: Double) {
        let mine = model.garage.cars.count == 1 ? manifests : manifests.filter { car.matches($0.car) }
        return (mine.count, mine.reduce(0) { $0 + ($1.highlights?.distanceMeters ?? 0) })
    }

    // MARK: Achievements

    private var achievements: some View {
        VStack(alignment: .leading, spacing: 0) {
            let earned = AchievementCatalog.all.filter { model.achievements.isUnlocked($0) }.count
            sectionTitle("Achievements", trailing: "\(earned) of \(AchievementCatalog.all.count)")
            AchievementsRow()
        }
    }

    // MARK: Highlights

    private var highlights: some View {
        let names = Dictionary(model.tracks.all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let autocross = Set(model.tracks.all.filter { $0.trackKind == .autocross }.map(\.id))
        let s = ProfileStats.compute(manifests, period: period, trackNames: names, autocross: autocross)
        let units = UnitsFormatter(metric: metric)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Highlights") {
                Menu {
                    Picker("Period", selection: $period) {
                        ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(period.title)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                }
            }
            LazyVGrid(columns: grid, spacing: 10) {
                StatTile(label: "Sessions", value: "\(s.sessions)")
                StatTile(label: "Drive time", value: String(format: "%.1f", s.seconds / 3600), unit: "h")
                StatTile(label: "Distance", value: "\(Int(units.distance(fromMeters: s.meters).rounded()))",
                         unit: units.distanceUnit)
                StatTile(label: "Track laps", value: "\(s.laps)")
            }
            let records = s.records.filter { !$0.isBestLap }
            let laps = s.records.filter(\.isBestLap)
            if !records.isEmpty {
                subTitle("Records")
                LazyVGrid(columns: grid, spacing: 10) {
                    ForEach(records) { r in
                        NavigationLink(value: r.session) { RecordTile(record: r, units: units) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !laps.isEmpty {
                subTitle("Best laps")
                VStack(spacing: 0) {
                    ForEach(Array(laps.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 52) }
                        NavigationLink(value: r.session) {
                            BestLapRow(record: r, date: manifests.first { $0.id == r.session }?.startedAtUTC)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func subTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.muted)
            .padding(.top, 8)
    }

    private func sectionTitle(_ title: String, trailing: String? = nil) -> some View {
        sectionTitle(title) {
            if let trailing { Text(trailing) }
        }
    }

    /// Section header with an orange control on the right (a count, a
    /// button, a menu).
    private func sectionTitle<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.numeral(20, weight: .bold))
                .foregroundStyle(Color(hex: 0x8A8A8A))
            Spacer()
            trailing()
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accent)
                .tint(Color.accent)
        }
        .padding(.top, 26)
        .padding(.bottom, 2)
    }
}
// MARK: - Pieces

private struct GarageRow: View {
    let car: GarageCar
    let photo: UIImage?
    let stats: (sessions: Int, meters: Double)
    let selected: Bool
    let metric: Bool
    let photoVersion: Int

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFit()
                } else {
                    Image(systemName: "car.side")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.muted)
                }
            }
            .frame(width: 120, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(car.title)
                    .font(.sofia(20, .bold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if !car.subtitle.isEmpty {
                    Text(car.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.muted)
                }
                Text("\(stats.sessions) session\(stats.sessions == 1 ? "" : "s") · \(distance)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 20)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var distance: String {
        let u = UnitsFormatter(metric: metric)
        return "\(Int(u.distance(fromMeters: stats.meters).rounded())) \(u.distanceUnit)"
    }
}

private struct BestLapRow: View {
    let record: ProfileStats.Record
    let date: Date?

    var body: some View {
        if case .bestLap(let id, let name, let autocross) = record.kind {
            HStack(spacing: 14) {
                Group {
                    if autocross {
                        Image(systemName: "flag.pattern.checkered").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accent)
                    } else {
                        CircuitGlyph()
                            .stroke(Color.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            .frame(width: 22, height: 22)
                    }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AchievementCatalog.all.first { $0.trackId == id }?.shortName ?? name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if let date {
                        Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.muted)
                    }
                }
                Spacer(minLength: 8)
                Text(RunFormat.time(record.value))
                    .font(.sofiaNumeral(22, .bold))
                    .foregroundStyle(Color.textPrimary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mutedWeak)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.sofiaNumeral(32, .bold)).foregroundStyle(Color.textPrimary)
                if let unit { Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RecordTile: View {
    let record: ProfileStats.Record
    let units: UnitsFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            icon
                .frame(height: 26, alignment: .leading)
                .padding(.bottom, 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.0).font(.sofiaNumeral(26, .bold)).foregroundStyle(Color.textPrimary)
                if !value.1.isEmpty {
                    Text(value.1).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted)
                }
            }
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        switch record.kind {
        case .bestLap(_, _, let autocross) where !autocross:
            CircuitGlyph()
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 26, height: 26)
        default:
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.accent)
        }
    }

    private var symbol: String {
        switch record.kind {
        case .topSpeed: return "gauge.with.dots.needle.67percent"
        case .cornering: return "steeringwheel"
        case .braking: return "exclamationmark.brakesignal"
        case .maxRpm: return "gauge.with.dots.needle.100percent"
        case .longest: return "timer"
        case .bestLap: return "flag.pattern.checkered"
        }
    }

    private var label: String {
        switch record.kind {
        case .topSpeed: return "Top speed"
        case .cornering: return "Peak cornering"
        case .braking: return "Peak braking"
        case .maxRpm: return "Max RPM"
        case .longest: return "Longest session"
        case .bestLap(let id, let name, _):
            let short = AchievementCatalog.all.first { $0.trackId == id }?.shortName ?? name
            return "Best lap · \(short)"
        }
    }

    private var value: (String, String) {
        switch record.kind {
        case .topSpeed: return ("\(Int(units.speed(fromMps: record.value).rounded()))", units.speedUnit.lowercased())
        case .cornering, .braking: return (String(format: "%.2f", record.value), "g")
        case .maxRpm: return (record.value.formatted(.number.precision(.fractionLength(0))), "")
        case .longest: return (SessionCard.duration(record.value), "")
        case .bestLap: return (RunFormat.time(record.value), "")
        }
    }
}

// MARK: - Profile storage

enum ProfileKeys {
    static let firstName = "profileFirstName"
    static let lastName = "profileLastName"
    static let email = "profileEmail"
    private static let joinedKey = "profileJoined"

    static var photoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveData/profile-photo.jpg")
    }

    /// The month the driver started: the first session, or first launch.
    static func joined(_ manifests: [SessionManifest]) -> Date {
        let first = manifests.map(\.startedAtUTC).min() ?? Date()
        let stored = UserDefaults.standard.object(forKey: joinedKey) as? Date ?? first
        let joined = min(first, stored)
        UserDefaults.standard.set(joined, forKey: joinedKey)
        return joined
    }

    /// Engraved on achievements: first name, or the older single name field.
    static var engravedName: String {
        let d = UserDefaults.standard
        let first = d.string(forKey: firstName) ?? ""
        return first.isEmpty ? (d.string(forKey: "driverName") ?? "") : first
    }
}

/// The driver's photo, or a racing-helmet placeholder.
struct ProfilePhotoView: View {
    var size: CGFloat
    @AppStorage("profilePhotoVersion") private var version = 0

    var body: some View {
        Group {
            if let img = UIImage(contentsOfFile: ProfileKeys.photoURL.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                HelmetPlaceholder()
            }
        }
        .id(version)
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct HelmetPlaceholder: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 64
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x2B2B2D)))
            var shell = Path()
            shell.move(to: p(12, 40))
            shell.addCurve(to: p(34, 16), control1: p(12, 26), control2: p(21, 16))
            shell.addCurve(to: p(53, 34), control1: p(45, 16), control2: p(53, 23))
            shell.addLine(to: p(53, 42)); shell.addLine(to: p(12, 42)); shell.closeSubpath()
            ctx.fill(shell, with: .color(.accent))
            var visor = Path()
            visor.move(to: p(30, 26)); visor.addLine(to: p(52, 26))
            visor.addQuadCurve(to: p(53, 35), control: p(53, 30)); visor.addLine(to: p(30, 35))
            visor.addQuadCurve(to: p(30, 26), control: p(27, 30.5)); visor.closeSubpath()
            ctx.fill(visor, with: .color(Color(hex: 0x111111)))
            ctx.fill(Path(CGRect(x: 14 * s, y: 42 * s, width: 40 * s, height: 6 * s)), with: .color(Color(hex: 0x1B1B1B)))
            var stripe = Path(); stripe.move(to: p(16, 34)); stripe.addLine(to: p(28, 34))
            ctx.stroke(stripe, with: .color(.white), style: StrokeStyle(lineWidth: 2.5 * s, lineCap: .round))
        }
    }
}

// MARK: - Sheets

private struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProfileKeys.firstName) private var firstName = ""
    @AppStorage(ProfileKeys.lastName) private var lastName = ""
    @AppStorage(ProfileKeys.email) private var email = ""
    @AppStorage("profilePhotoVersion") private var photoVersion = 0
    @State private var pick: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        ProfilePhotoView(size: 96)
                        PhotosPicker(selection: $pick, matching: .images) {
                            Text("Choose photo").font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("First name", text: $firstName).textContentType(.givenName)
                    TextField("Last name", text: $lastName).textContentType(.familyName)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Your first name is engraved on the back of your track achievements.")
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.85) else { return }
                    try? jpg.write(to: ProfileKeys.photoURL, options: .atomic)
                    photoVersion += 1
                    EmblemThumbnailCache.images.removeAll()
                }
            }
        }
        .tint(Color.accent)
    }
}

private struct AddCarSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Editing an existing car instead of adding one.
    var editing: GarageCar?
    @State private var make = ""
    @State private var carModel = ""
    @State private var year = ""
    @State private var color = ""
    @State private var pick: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Group {
                            if let image { Image(uiImage: image).resizable().scaledToFit() }
                            else {
                                Image(systemName: "car.side").font(.system(size: 48, weight: .light))
                                    .foregroundStyle(Color.muted)
                            }
                        }
                        .frame(height: 120)
                        PhotosPicker(selection: $pick, matching: .images) {
                            Text(image == nil ? "Choose a photo" : "Choose another")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("The background is removed on your phone, so any photo of the car works.")
                }
                Section {
                    Menu("Pick a common car") {
                        ForEach(PreferredCar.presets) { p in
                            Button(p.displayName) {
                                make = p.make; carModel = p.model; year = p.year.map(String.init) ?? ""
                            }
                        }
                    }
                    TextField("Make", text: $make)
                    TextField("Model", text: $carModel)
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Colour", text: $color)
                }
            }
            .navigationTitle(editing == nil ? "Add a car" : "Edit car")
            .onAppear {
                guard let car = editing, make.isEmpty else { return }
                make = car.make; carModel = car.model
                year = car.year.map(String.init) ?? ""; color = car.color ?? ""
                image = model.garage.photo(for: car)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(make.trimmingCharacters(in: .whitespaces).isEmpty
                                  || carModel.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        image = img
                    }
                }
            }
        }
        .tint(Color.accent)
    }

    private func save() {
        saving = true
        if var car = editing {
            car.make = make.trimmingCharacters(in: .whitespaces)
            car.model = carModel.trimmingCharacters(in: .whitespaces)
            car.year = Int(year)
            car.color = color.isEmpty ? nil : color
            model.garage.update(car)
            let picked = pick != nil ? image : nil
            Task {
                if let picked { await model.garage.setPhoto(picked, for: car.id) }
                dismiss()
            }
            return
        }
        let car = GarageCar(make: make.trimmingCharacters(in: .whitespaces),
                            model: carModel.trimmingCharacters(in: .whitespaces),
                            year: Int(year), color: color.isEmpty ? nil : color)
        Task {
            await model.garage.add(car, photo: image)
            dismiss()
        }
    }
}
