export function companyColorClasses(companyId: string, color: string): [string, string] {
    switch (color) {
        case "red": return ["bg-red-500", "text-white"]
        case "yellow": return ["bg-yellow-500", "text-black"]
        case "blue": return ["bg-blue-500", "text-white"]
        case "green": return ["bg-green-500", "text-white"]
        case "purple": return ["bg-purple-500", "text-white"]
        case "cyan": return ["bg-cyan-500", "text-white"]
        case "orange": return ["bg-orange-500", "text-white"]
        default: return companyId === "0" ? ["bg-slate-200", "text-black"] : ["bg-slate-800", "text-white"]
    }
}